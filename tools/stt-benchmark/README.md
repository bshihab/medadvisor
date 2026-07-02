# MedAdvisor STT + LLM-attribution benchmark

Tests, on your Mac laptop, the two questions we discussed:

1. **Transcription accuracy** — Whisper vs Parakeet vs Apple, on 100 generated
   doctor–patient conversations, each run **3×** (300 runs/engine). We generate
   the transcripts ourselves, so we know the ground truth; audio is synthesized
   with macOS `say`. Metric: **WER** (word error rate, lower = better).

2. **LLM-only speaker detection** — can MedGemma alone split a *flat* transcript
   (no diarization, no timestamps) into Doctor/Patient? Metric: **word-level
   attribution accuracy** (higher = better). This is the "do we even need
   diarization?" test.

> **Caveat we already discussed:** `say` audio is clean/synthetic, so absolute
> WER will be optimistic vs real mic audio. But the *relative* ranking of the
> engines is still meaningful. The LLM-attribution test uses text only, so it's
> unaffected by audio realism.

## The models

| Engine | How it runs here | Notes |
|---|---|---|
| **Whisper** | `mlx-whisper` (Apple Silicon) | `small.en`, same tier as the app |
| **Parakeet** | `parakeet-mlx` (Apple Silicon) | TDT v2/v3, same family as the app |
| **Apple** | `apple/AppleTranscribe.swift` | **macOS 26 only**, run separately |
| **LLM** | `llama-cpp-python` + MedGemma 4B `Q4_K_M` GGUF | same model as the app |

## Setup

```bash
cd tools/stt-benchmark
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
brew install ffmpeg     # audio decoding for the STT libs
```

Download the same LLM the app uses (once):

```bash
pip install huggingface_hub
huggingface-cli download unsloth/medgemma-4b-it-GGUF \
  medgemma-4b-it-Q4_K_M.gguf --local-dir ./models
```

## Run

```bash
# 1) Generate 100 conversations + synthesize audio (writes data/)
python generate_dataset.py --n 100

# 2) Whisper vs Parakeet, 3 runs each (writes results/stt.json + prints table)
python bench_stt.py --runs 3

# 3) LLM-only attribution with MedGemma (writes results/attribution.json)
python bench_llm_attribution.py --model ./models/medgemma-4b-it-Q4_K_M.gguf

# 4) (optional) Apple, on macOS 26 — transcribe the same audio, then score it
swift apple/AppleTranscribe.swift data/audio results/apple_raw.json
python score_apple.py            # computes Apple's WER against ground truth
```

## Reading the results

- `bench_stt.py` prints mean WER per engine, overall and by conversation length.
- `bench_llm_attribution.py` prints two numbers per session and overall:
  - **separation accuracy** — best of the two Doctor/Patient label mappings
    (measures whether it split the voices correctly, ignoring which label).
  - **role accuracy** — as-labeled (also got Doctor vs Patient right).

If Parakeet's WER is clearly lowest and the LLM's attribution is high on short/
clean convos but drops on long/fast ones, that confirms the app's design:
**Parakeet for words, diarization for boundaries, LLM for role.**

## Notes / gotchas

- Exact `mlx-whisper` / `parakeet-mlx` call signatures shift between versions —
  if an import or `.transcribe()` call fails, check the installed version's
  README; the engine wrappers in `engines.py` are small and easy to tweak.
- The Apple step is optional and only works on macOS 26 with the Speech
  framework's `SpeechAnalyzer`/`SpeechTranscriber`.
