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
