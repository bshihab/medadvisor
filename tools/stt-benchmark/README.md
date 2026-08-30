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

## Results

### Transcription (WER — lower is better)

| Engine | WER | n | Download | Measured |
|---|---|---|---|---|
| **Whisper `small.en`** (MLX) | **1.1%** | 10 convos × 3 runs | ~480 MB | 2026-07-01, MacBook Air |
| **Apple SpeechAnalyzer** | **3.2%** | 10 convos | **none** (in-OS) | 2026-07-01, macOS 26 |
| **Apple SpeechAnalyzer** | **3.1%** | **30 convos** | **none** (in-OS) | 2026-07-25, macOS 26.3.1 (replication) |
| **Cohere Transcribe** (2B, transformers) | **1.7%** | **30 convos** | ~4.1 GB | 2026-08-30, Mac mini M4 (MPS) — *not runnable in the app, see below* |
| Parakeet TDT | *not measured* | — | ~2.5 GB (MLX build) | run abandoned — the download alone was ~75 min |

Whisper per-conversation WER: 1.6, 2.9, 0, 0.5, 0.8, 0, 1.6, 1.1, 2.8, 0.
Whisper is deterministic here — all 3 runs per conversation scored identically,
so the repeats measure timing, not accuracy.

**Apple, 30-conversation replication (2026-07-25)** — 5,555 reference words,
28.5 min of audio:

```
===== APPLE STT WER (lower is better) =====
  overall: 3.1%  (n=30)
  short (<=10 turns)     4.0%
  medium (11-24)         3.0%
  long (25+)             3.1%
```

median 3.0% · stdev 1.6% · range 0.0–7.8% · **28.5 min of audio transcribed in
43 s ≈ 40× realtime**, at ~6% CPU (the Neural Engine does the work).

Two things matter more than the headline number:
- **Accuracy is flat across conversation length** (4.0 / 3.0 / 3.1%). It does not
  degrade on long recordings — the failure mode that would actually hurt a
  15-minute consultation.
- **The n=10 → n=30 replication landed within 0.1%**, so 3.2% was a real
  measurement, not small-sample noise.

**Cohere Transcribe, same 30 conversations (2026-08-30)** — the identical gold
set, WER function and length buckets, one pass per clip
(`bench_cohere_transcribe.py`):

```
===== COHERE TRANSCRIBE WER (lower is better) =====
  overall: 1.7%  (n=30)
  short (<=10 turns)     0.0%
  medium (11-24)         1.9%
  long (25+)             1.7%
```

median 1.1% · stdev 1.6% · range 0.0–5.7% · per clip: 0.5, 3.8, 0, 1.0, 2.0, 0,
1.6, 2.7, 5.7, 0, 1.1, 0.9, 0, 0.7, 1.0, 1.2, 1.2, 1.3, 2.0, 3.6, 0, 1.0, 0, 0.9,
3.6, 0.8, 5.3, 3.1, 1.7, 4.4. Head-to-head on the same clips it beat Apple on 26,
tied on 2 and lost on 2. (Only 2 of the 30 conversations fall in the *short*
bucket, so that 0.0% is two clips, not a trend.)

**Throughput, Mac-side only (Apple M4 Mac mini, MPS, bf16 — not an iPhone
number):** 28.5 min of audio in 103 s ≈ 17× realtime, median 3.3 s per clip
(range 1.5–5.9 s), plus ~5 s to load the weights. All 30 clips ran on MPS; the
CPU fallback was never needed.

Read this row honestly:

- **It is not something MedAdvisor can run on-device today.** Apple's
  SpeechAnalyzer is in the OS; Transcribe is a 2B-parameter conformer
  encoder-decoder that ran here through PyTorch/transformers on a Mac GPU. The
  app's iPhone inference stack is llama.cpp, which runs LLMs, not conformer ASR,
  and there is no Core ML or MLX port of this model in the app. So this measures
  **the model's quality**, not a shippable engine swap — it is a data point for
  a future decision, not a candidate for the next build.
- **Its residual errors are formatting, not recognition.** Of the 83 word edits
  across 5,919 reference words, 82 are the model writing numerals and
  abbreviations where the references spell them out (`one`→`1`, `ten`→`10`,
  `six`→`6`, `Doctor`→`Dr.`) and one is `alright`→`all right`. The scoring is
  deliberately left identical to the other engines (Apple writes `Dr.` too and
  pays the same penalty), so the 1.7% is comparable but overstates its real
  miss rate on this clean audio, which is close to zero. Same caveat as
  everything else here: synthetic `say` audio, no medical vocabulary, no
  accents or noise.
- **The thing worth watching is language coverage.** Transcribe ships one
  model for 14 languages (English, French, German, Italian, Spanish,
  Portuguese, Greek, Dutch, Polish, Mandarin, Japanese, Korean, Vietnamese,
  Arabic; Apache 2.0). That is the differentiator if MedAdvisor ever needs
  non-English consultations — and the reason to re-run this benchmark the day
  a conformer runtime exists for the phone.

### LLM-only speaker attribution (Qwen2.5-7B-4bit, 15 cases)

```
separation:  73.6%   (split the two voices)
role:        68.1%   (also got which is the Doctor)
```

Too low to trust a flat transcript to the LLM alone — which is why the app feeds
it **fixed per-utterance boundaries** (from the live transcript's pause
segmentation) and only asks it to *classify* each utterance, never to guess
where turns break.

### Why Apple shipped despite losing on WER

Whisper was ~3× more accurate here (1.1% vs 3.1–3.2%), yet **WhisperKit was
removed from the app** (commit `b35a61e`) and Apple is now the only engine. That
was a deliberate trade, not an accuracy claim:

- **The absolute gap is immaterial for this app.** 1.1% vs 3.1% is ~1 vs ~3 wrong
  words per 100 — on a 300-word consultation, ~3 vs ~9. The rubric scoring reads
  for *meaning* ("did the clinician introduce themselves?"), which doesn't hinge
  on a few stray words. *Which* words are wrong (a drug name, a negation) matters
  far more than how many, and this clean-audio test cannot measure that.
- **Apple costs nothing to ship**: no ~480 MB first-run download, smaller app,
  faster builds, no model management, and it is dramatically more power- and
  thermal-efficient (40× realtime on the ANE).
- **It proved adequate in real use.** Weeks of real recordings on-device never
  showed Apple's accuracy to be the limiting factor — the scoring LLM was.
- Parakeet came bundled with FluidAudio; removing the diarizer took it with it.

**Do not describe Apple as having "matched" Whisper** — no measurement supports
that. It was measurably less accurate on synthetic audio and shipped anyway,
for the reasons above.

### Caveats on all of the above

- `say` audio is clean and synthetic: **every number here is optimistic** versus
  real mic audio with accents, crosstalk, and room noise.
- Each line is synthesized separately, so nothing here tests overlapping speech.
- **Medical vocabulary is untested** — the gap most likely to matter clinically.
- Whisper and Parakeet are no longer in the app, so this table is a record of how
  the decision was made, not a live comparison.
- Cohere Transcribe was never in the app and was measured on a Mac, not a phone.

## The models

| Engine | How it runs here | Notes |
|---|---|---|
| **Whisper** | `mlx-whisper` (Apple Silicon) | `small.en`, same tier the app used |
| **Parakeet** | `parakeet-mlx` (Apple Silicon) | TDT v2/v3; ~2.5 GB in the MLX build |
| **Apple** | `apple/AppleTranscribe.swift` | **macOS 26 only**, run separately. Needs no deps beyond `jiwer` — see below |
| **Cohere Transcribe** | `bench_cohere_transcribe.py` — transformers on torch (MPS, CPU fallback), own venv | `CohereLabs/cohere-transcribe-03-2026`, 2B, Apache 2.0; gated repo, ~4.1 GB download. See `requirements-cohere-transcribe.txt` |
| **LLM** | `mlx-lm` (MedGemma 4B originally; Qwen2.5-7B in the recorded run) | attribution test only |

> **Apple-only re-run (cheap):** you do not need the MLX engines. A venv with just
> `jiwer` (~18 MB) is enough, since `engines.py` imports the heavy libraries lazily:
> ```bash
> python3 -m venv .venv-apple && ./.venv-apple/bin/pip install jiwer
> ./.venv-apple/bin/python generate_dataset.py --n 30
> swift apple/AppleTranscribe.swift data/audio results/apple_raw.json
> ./.venv-apple/bin/python score_apple.py
> ```

## Setup

```bash
cd tools/stt-benchmark
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
brew install ffmpeg     # audio decoding for the STT libs
```

Model weights download automatically on first run (Whisper/Parakeet from
`bench_stt.py`, MedGemma from `bench_llm_attribution.py`) — no manual download.

## Run

```bash
# 1) Generate 100 conversations + synthesize audio (writes data/)
python generate_dataset.py --n 100

# 2) Whisper vs Parakeet, 3 runs each (writes results/stt.json + prints table)
python bench_stt.py --runs 3

# 3) LLM-only attribution with MedGemma (auto-downloads the MLX model)
python bench_llm_attribution.py

# 4) (optional) Apple, on macOS 26 — transcribe the same audio, then score it
swift apple/AppleTranscribe.swift data/audio results/apple_raw.json
python score_apple.py            # computes Apple's WER against ground truth

# 5) (optional) Cohere Transcribe — separate venv (torch + transformers, not MLX).
#    Gated repo: click "agree" once on huggingface.co/CohereLabs/cohere-transcribe-03-2026,
#    then `hf auth login`. First run downloads ~4.1 GB; keep ~5 GB free.
python3 -m venv .venv-transcribe && ./.venv-transcribe/bin/pip install -r requirements-cohere-transcribe.txt
./.venv-transcribe/bin/python bench_cohere_transcribe.py --limit 1   # smoke test: prints hyp vs ref
./.venv-transcribe/bin/python bench_cohere_transcribe.py             # full n=30 → results/cohere_transcribe*.json
```

> If the default MedGemma MLX model id 404s, pass `--model <id>` — search
> huggingface.co/mlx-community for a `medgemma-4b-it` build (e.g. 4bit/8bit).

## Reading the results

- `bench_stt.py` prints mean WER per engine, overall and by conversation length.
- `bench_cohere_transcribe.py` prints the same WER summary plus per-clip
  wall-clock (Mac-side, not iPhone) and writes `results/cohere_transcribe.json`
  (scored rows + run metadata) and `results/cohere_transcribe_raw.json`
  (`{id: transcript}`, the same shape as `apple_raw.json`).
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
- Cohere Transcribe prefers MPS (bf16) and reloads on CPU (fp32) if MPS fails at
  load or on a clip; `PYTORCH_ENABLE_MPS_FALLBACK=1` is set by `engines.py` so a
  single unsupported op falls back per-op instead of crashing. Clips over 35 s
  are chunked by the processor and re-joined in `decode`, per the model card.
  The gold set is already 16 kHz mono; anything else is converted into a temp
  copy with ffmpeg — the source files are never modified.
