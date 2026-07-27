# Model comparison — can anything replace Qwen2.5-7B?

**Measured 2026-07-25 → 27 on the `ane-experiment` branch. The shipping path
(llama.cpp + Qwen2.5-7B, `LlamaEngine`/`LlamaContext`) was never modified.**

Raw per-decision rows land in `results/`, which this repo gitignores — so this
file is the durable record. Every number below was produced by the same code:
`app_scoring.py` (the port of `Analysis.swift`) for prompts, parsing and the
evidence guardrail, so all rows are directly comparable.

## Headline

| Configuration | Acc (240) | False praise | Wrongly denied | Recall | Size | Attribution |
|---|---|---|---|---|---|---|
| **Qwen3.5-4B, thinking off** | **85.4%** | 35/112 | **0/128** | **100%** | **2.4 GB** | **100%** |
| Qwen2.5-7B + few-shot | 83.8% | **27/112** | 12/128 | 90.6% | 4.3 GB | 92.1% |
| Qwen3.5-4B no-think + few-shot | 81.7% | 44/112 | 0/128 | 100% | 2.4 GB | — |
| **Qwen2.5-7B stock — SHIPS TODAY** | 79.2% | 41/112 | 9/128 | 93.0% | 4.3 GB | 92.1% |
| Qwen3-4B-Instruct-2507 + few-shot | 79.2% | 44/112 | 6/128 | 95.3% | 2.4 GB | 92.6% |
| Qwen3-4B-Instruct-2507 stock | 72.9% | 65/112 | 0/128 | 100% | 2.4 GB | 92.6% |
| Qwen2.5-3B stock | 70.8% | 40/112 | 30/128 | 76.6% | 1.8 GB | 85.5% |
| Qwen2.5-3B + few-shot | 60.0% | 56/112 | 40/128 | 68.8% | 1.8 GB | — |

Test sets: **240 decisions** = 15 snippet-assembled transcripts (`bench_scoring.py`,
128 met / 112 missed). **48 decisions** = 3 hand-written consultations
(`bench_realistic.py`, 18 met / 30 missed). Attribution = hand-written
transcripts, numbered-utterance format (`bench_attribution_numbered.py --realistic`).

**Two configurations beat what ships, and they fail differently:**
- **Qwen3.5-4B** gets 4 more decisions right and *never* denies a real behavior —
  but all 35 of its errors are false praise. Structurally a lenient grader.
- **7B + few-shot** commits 8 fewer acts of false praise, at the cost of 12
  wrongly-denied credits.

Which is preferable is a product judgment for the director, not a benchmark
result. `PLAN.md`'s own principle — wrong feedback is worse than none — argues
for minimising false praise.

## Shipping either one

**Switch to Qwen3.5-4B** (three changes, no new frameworks):
1. `bartowski/Qwen_Qwen3.5-4B-GGUF` Q4_K_M → your R2 bucket (same publisher as
   the current 7B GGUF; `lmstudio-community` and `unsloth` also publish it).
2. `ModelDownloader.swift` — URL + `fileName` constants.
3. `LlamaEngine.swift:70` — **disable reasoning mode**, see below.

**Add few-shot to the 7B**: port `FEW_SHOT_BLOCK` from `app_scoring.py` into
`PromptBuilder.scoringPrefix`. It sits inside the KV-cached shared prefix, so
its ~170 tokens are prefilled once per analysis, not 16×.

### Disabling reasoning mode needs no GGUF or llama.cpp support

Qwen3/3.5 are reasoning models. Left alone they emit a long `Thinking Process:`
block and never reach an answer inside the app's token budget — measured:
Qwen3.5-4B labeled **1 of 21** utterances and scored 6.7% attribution / 0%
recall. That is a configuration artifact, not a capability limit.

Thinking-off is purely textual:

```
ON:   <|im_start|>assistant\n<think>\n
OFF:  <|im_start|>assistant\n<think>\n\n</think>\n\n
```

The app hand-builds ChatML, so this is a one-string change and works with any
GGUF and any llama.cpp build — no `--jinja`, no `--chat-template-kwargs`, no
version floor:

```swift
// LlamaEngine.swift — pre-fill an empty think block to suppress reasoning
let fullSuffix = suffix + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
```

Benchmarks use `--no-think` on `bench_scoring.py` / `bench_realistic.py` /
`bench_attribution_numbered.py`, which asks the template for
`enable_thinking=False` and falls back to Qwen's `/no_think` soft switch.

## Findings that cost real time to learn

**Few-shot is model-specific, not size-specific.** Helps Qwen2.5-7B (+4.6) and
Qwen3-4B (+6.3); hurts Qwen3.5-4B (−3.7), Qwen2.5-3B (−10.8) and Apple's ~3B
(−13.9). Qwen3-4B and Qwen3.5-4B are the same size and respond oppositely, so
"bigger models benefit" is wrong. Measure per model.

**The 48-case set cannot separate models by a few points.** Qwen2.5-3B scored
85.4% there and 70.8% on 240 — it is only 37.5% "met", so it under-punishes
under-crediting. Always confirm on the 240-decision set. Qwen3.5-4B held up on
both (89.6% / 85.4%), which is what a real result looks like.

**Benchmark the stock candidate BEFORE fine-tuning it.** Six LoRA
configurations on Qwen2.5-3B, all *worse* than leaving it alone (85.4% stock vs
81.2% best fine-tune). The base model was already well-calibrated at 6.7%
over-score — better than the 7B — so training could only substitute authored
labels for good priors. The July-1 bake-off's "at 4B models fail in both
directions" was measured on MedGemma-4B and Gemma-3-4B, never on a small Qwen.

**Fine-tuning collapses into constant answers on repetitive prompts.** All 630
grading examples share a near-identical ~950-token prompt; the cheapest loss
reduction is a constant output. At 100 iters the model answered "missed" to
everything, by 200 iters "met" to everything.

**Two dataset bugs worth avoiding** (both caught by held-out tests, not by
validation loss):
1. *Goodhart on the unmeasured output.* Reusing one canned tip string for every
   absent criterion collapsed coaching tips from 39 distinct to 5 while verdict
   accuracy improved. `gen_finetune_dataset.py` now generates tips per criterion
   from the rubric's `whatGoodLooksLike`.
2. *Positional shortcut.* Every attribution example opened with a Patient line,
   so the model learned "utterance 1 = Patient" and scored 100% on synthetic
   data but 30.2% role / 96.8% separation on real consultations — a systematic
   inversion. Openers are now randomised.

**The July-1 diarization decision rests on a retired prompt.** "LLM attribution
too weak, keep FluidAudio" came from 73.6% separation / 68.1% role on the
whole-transcript *reconstruction* prompt. On the numbered format the app now
ships, the 7B scores 92.1% and Qwen3.5-4B scores 100%. Worth revisiting.

## What is NOT verified — read before shipping anything

1. **The director's gold scores.** Every number here measures agreement with
   hand-authored labels. "Beats the 7B" means "agrees with me more than the 7B
   does", not "is more clinically correct". This gates everything.
2. **Prose quality was never scored** — for any model, in any run. Summaries and
   tips have no automated metric. This is exactly the blind spot that hid the
   tip-diversity collapse.
3. **On-device**: no speed, memory or thermal measurement for any 4B under
   llama.cpp. A 4B should improve substantially on the 7B's ~5%/analysis and
   `serious` thermal, but that is an expectation, not a measurement.
4. **GGUF fidelity**: that `<think>`/`</think>` survive conversion as single
   tokens has not been checked on the actual GGUF.
5. Attribution used 3 hand-written transcripts (41 utterances) — small.

## Reproduce

```bash
cd tools/llm-benchmark && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest test_app_scoring.py -q          # 18 port-fidelity tests
.venv/bin/python generate_scoring_dataset.py --n 15         # the 240-decision set

# grading
.venv/bin/python bench_scoring.py   --model mlx-community/Qwen3.5-4B-4bit --no-think
.venv/bin/python bench_realistic.py --model mlx-community/Qwen3.5-4B-4bit --no-think
APP_SCORING_FEW_SHOT=1 .venv/bin/python bench_scoring.py \
  --model mlx-community/Qwen2.5-7B-Instruct-4bit           # the +few-shot arm

# speaker attribution, the format the app actually uses
.venv/bin/python bench_attribution_numbered.py --model mlx-community/Qwen3.5-4B-4bit \
  --no-think --realistic

# fine-tuning (for the record — it did not help grading)
.venv/bin/python gen_finetune_dataset.py
.venv/bin/python -m mlx_lm.lora --model mlx-community/Qwen2.5-3B-Instruct-4bit \
  --train --data data/finetune --iters 300 --batch-size 1 --num-layers 16 \
  --max-seq-length 1600 --learning-rate 5e-5 --save-every 100 \
  --adapter-path adapters/qwen3b-v2
```

Apple foundation-model track (separate question, separate outcome): see
`FM-RESULTS.md`. Harness fidelity vs `Analysis.swift`: see `PORT-DIFF.md`.
