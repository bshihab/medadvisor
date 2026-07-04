# MedAdvisor LLM benchmark

Tests the two LLM jobs in the app, one model at a time (verbose progress):

1. **Rubric scoring** (`bench_scoring.py`) — **the important one.** Does the model
   apply the rubric correctly? We author transcripts where each criterion is
   known **met** or **missed**, run the model through the app's *exact* scoring
   prompt + evidence guardrail, and measure:
   - **accuracy** (met/missed correct)
   - **over-score** — % of MISSED criteria wrongly marked met (*the bug we care about*)
   - **recall(met)** — % of MET criteria correctly marked met
2. **Speaker attribution** (`bench_attribution.py`) — can the model split
   Doctor/Patient from a flat transcript (the "do we need diarization?" question).
   Metrics: separation + role accuracy.

Uses `app_scoring.py`, a faithful Python port of `Analysis.swift` (prompt +
parser + guardrail), so it measures what actually ships.

## Results (2026-07-01) — Qwen 2.5-7B wins

Realistic test (3 hand-written consultations, 48 criterion decisions). The metric
that matters is **over-score** — how often a genuinely-**absent** behavior is
wrongly marked "met" (the "feedback rubber-stamps everything" complaint):

| Model | Size (Q4) | Over-score ↓ | Recall(met) ↑ | Accuracy | Read |
|---|---|---|---|---|---|
| **Qwen 2.5-7B** | **4.3 GB** | **3.3%** | **94%** | **96%** | ✅ **balanced — winner** |
| Gemma 3 4B | 2.5 GB | 3.3% | 56% | 81% | too strict (under-credits) |
| **MedGemma 4B** (was default) | 2.5 GB | **53%** | 94% | 65% | too lenient — rubber-stamps |
| Gemma 4 E4B | 8.8 GB | 0% | 0% | 63% | broken output + too big — out |

### Raw benchmark output (verbatim)

Qwen 2.5-7B — realistic test:
```
============ REALISTIC SCORING SUMMARY ============
model:        mlx-community/Qwen2.5-7B-Instruct-4bit
accuracy:      95.8%   (46/48)
over-score:     3.3%   (1/30 MISSED wrongly marked met)  ← lower better
recall(met):   94.4%   (17/18 MET correctly marked met)   ← higher better
```

Gemma 3 4B — realistic test:
```
============ REALISTIC SCORING SUMMARY ============
model:        mlx-community/gemma-3-4b-it-4bit
accuracy:      81.2%   (39/48)
over-score:     3.3%   (1/30 MISSED wrongly marked met)  ← lower better
recall(met):   55.6%   (10/18 MET correctly marked met)   ← higher better
```

MedGemma 4B (was the app default) — realistic test:
```
============ REALISTIC SCORING SUMMARY ============
model:        mlx-community/medgemma-4b-it-4bit
accuracy:      64.6%   (31/48)
over-score:    53.3%   (16/30 MISSED wrongly marked met)  ← lower better
recall(met):   94.4%   (17/18 MET correctly marked met)   ← higher better
```

Gemma 4 E4B — realistic test (broken output — marked everything missed; also 8.8 GB):
```
============ REALISTIC SCORING SUMMARY ============
model:        mlx-community/gemma-4-e4b-it-OptiQ-4bit
accuracy:      62.5%   (30/48)
over-score:     0.0%   (0/30 MISSED wrongly marked met)  ← lower better
recall(met):    0.0%   (0/18 MET correctly marked met)   ← higher better
```

MedGemma 4B — larger snippet test (240 decisions), confirming the over-scoring:
```
================ SCORING SUMMARY ================
model:        mlx-community/medgemma-4b-it-4bit
accuracy:      59.6%   (143/240)
over-score:    81.2%   (91/112 MISSED criteria wrongly marked met)  ← lower is better
recall(met):   95.3%   (122/128 MET criteria correctly marked met)   ← higher is better
```

### What we learned
- **The model was the problem, not the app or prompt.** MedGemma 4B marked ~half
  of absent behaviors as "met" — that's why the feedback felt untrustworthy.
- **Medical fine-tuning *hurt* here.** The task is rubric-*applying* (reading
  comprehension + skeptical judgment + instruction-following), not medical recall
  — the rubric supplies the medical content. MedGemma's helpful-medical-assistant
  tuning biases it toward "yes, they did well" (over-scoring), and much of its
  training is for medical *images*, which is irrelevant here.
- **At 4B, models fail one way or the other** (MedGemma too lenient, Gemma-3 too
  strict). **Only a ~7B is balanced.** Qwen 7B is the largest model that still
  runs comfortably on an 8 GB iPhone (via llama.cpp mmap).
- **A parser bug mattered:** the app required an exact `RESULT:` label, but Qwen
  emits a bare `done` — which silently zeroed it (2.3% recall artifact) until the
  parser was made robust to unlabeled/`**bold**`/bare output. Fixed here and
  ported to `Analysis.swift`.

**Decision:** app LLM switched **MedGemma 4B → Qwen 2.5-7B-Instruct**. Follow-ups:
few-shot exemplars + the director's gold-score calibration (the true validation).

## Experiment: RAG scoring hypothesis (2026-07-03) — rejected by the data

**Hypothesis (Bilal):** instead of feeding the LLM the whole transcript 16×
(once per criterion), embed the transcript's turns once, retrieve the top-k
most relevant turns per criterion, and score against only those excerpts —
cutting per-call tokens (→ on-device time + heat for 15-minute visits).

**Test:** `bench_rag.py` — same cases, same model (Qwen 2.5-7B), same metrics;
`--mode full` vs `--mode rag` (MiniLM embeddings, top-6 turns).

**Result (realistic set, verbatim):**
```
========== FULL / realistic ==========        ========== RAG / realistic ==========
accuracy:      95.8%   (46/48)                accuracy:      79.2%   (38/48)
over-score:     3.3%   (1/30)                 over-score:     0.0%   (0/30)
recall(met):   94.4%   (17/18)                recall(met):   44.4%   (8/18)
avg prompt:      585 tokens/call              avg prompt:      406 tokens/call
avg latency:     2.3 s/call                   avg latency:     1.8 s/call
```

**Verdict:** retrieval misses the evidence turns often enough that the model —
correctly following its "no quote, no credit" rule — marks genuinely-done
behaviors as missed: **recall halved (94% → 44%)** for only a **31% token
saving**. Content criteria (accurate_info, explore_complaint, safety_net)
degraded most; structural ones (set_tone, what_else) held. A "you didn't do X"
verdict on something the doctor did is a trust-killer, so pure RAG scoring is
out. **Chosen fix instead: KV prefix caching** — process the shared
instructions+transcript once and reuse the model state across all 16 criteria;
identical tokens → identical accuracy, with the prefill cost paid once instead
of 16×. (RAG could be revisited as a hybrid — retrieval first, full-transcript
re-check for "missed" verdicts — if prefix caching ever proves insufficient.)

## Setup (light — no torch/whisper)

```bash
cd tools/llm-benchmark
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Run — one model at a time (gentle on a MacBook Air)

```bash
python generate_scoring_dataset.py --n 15      # labeled transcripts (once)

# Smoke-test a model on 2 cases first (fast), then the full set:
python bench_scoring.py --model mlx-community/Qwen2.5-7B-Instruct-4bit --limit 2
python bench_scoring.py --model mlx-community/Qwen2.5-7B-Instruct-4bit

# Attribution (optional):
python bench_attribution.py --model mlx-community/Qwen2.5-7B-Instruct-4bit --limit 2
```

Repeat with each model, then compare the printed summaries.

## Candidate models (MLX ids — verify on huggingface.co/mlx-community)

| Model | id (approx) |
|---|---|
| MedGemma 4B (baseline) | `mlx-community/medgemma-4b-it-4bit` |
| Gemma 3 4B (non-medical) | `mlx-community/gemma-3-4b-it-4bit` |
| Qwen2.5 7B | `mlx-community/Qwen2.5-7B-Instruct-4bit` |
| Llama 3.1 8B | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` |
| Phi-3.5-mini | `mlx-community/Phi-3.5-mini-instruct-4bit` |
| Gemma 4 (new) | check mlx-community for a small variant |

> Each 4-bit model is a **2–5 GB download** and generation is slow on an Air.
> Do them one at a time; use `--limit` to smoke-test before the full run.

## How many transcripts?

The unit that matters is **criterion-level decisions**, not transcripts — each
transcript = 16 criteria. So:
- **`--n 15`** → ~240 decisions/model → solid signal (recommended).
- **`--n 10`** → ~160 decisions → fine for a first pass.
- **`--n 5` / `--limit 5`** → quick smoke test to confirm a model runs + rough read.

## Honest caveats

- **Authored ground truth measures capability, not true correctness.** It catches
  over-scoring and gross errors. The *real* ground truth is the **director's gold
  scores** — this benchmark narrows the field; calibration decides the winner.
- Snippets are kept distinct, but one occasionally satisfies another criterion —
  adds a little noise. Over-score rate on clearly-omitted behaviors is the
  cleanest signal.
- The prose **summary** isn't scored here (no single right answer) — eyeball it or
  use an LLM-judge separately.
