# MedAdvisor

On-device AI feedback for medical trainees on their patient consultations. Records an encounter, scores it against a medical educator's rubric (communication **and** clinical conduct), and returns actionable feedback — **entirely on the device**. No audio or transcript leaves the phone.

See [PLAN.md](PLAN.md) for milestones and the privacy verification gate.

## On-device model choices (benchmarked)

Everything runs on the phone. The models were chosen by **benchmarking, not by label** — see [`tools/stt-benchmark`](tools/stt-benchmark) (speech) and [`tools/llm-benchmark`](tools/llm-benchmark) (rubric scoring).

| Job | Model | Why |
|---|---|---|
| **Rubric scoring (LLM)** | **Qwen 2.5-7B-Instruct** (Q4, ~4.3 GB) — default<br>**Qwen 3.5-4B** (Q4, ~3.0 GB) — selectable | Both run on llama.cpp. The 7B replaced MedGemma 4B, which rubber-stamped (**53% over-score**). A later 240-decision set — 5× the resolution of the first — then showed **Qwen 3.5-4B ahead of the 7B, 85.4% vs 79.2%**, on a 30% smaller download. Shipped as an opt-in while the director validates it. |
| Transcription | Apple SpeechAnalyzer (iOS 26, built-in) | On-device, no model download, live streaming with pause-segmented timestamps, ~40× realtime on the Neural Engine. **3.1% WER** (n=30) vs Whisper `small.en`'s 1.1% — Whisper was *more* accurate, but WhisperKit was removed anyway: ~3 vs ~9 wrong words per 300 doesn't move a rubric score that reads for meaning, and Apple costs no 480 MB download, no heat, no model management. |
| Diarization | LLM speaker attribution (per-utterance, role-aware) | The scoring LLM labels each utterance Doctor/Patient using content + anchor phrases; replaced a separate diarization model. |

**Key finding:** for rubric *scoring*, the task is judgment + instruction-following, **not** medical knowledge (the rubric supplies that) — so a strong *general* model beats a *medical* one. MedGemma 4B rubber-stamped half the rubric at 53% over-score.

**And bigger is not better either.** On a 48-decision set the 7B looked excellent (96% accuracy, 3.3% over-score). Widening to **240 decisions** — the same rubric, 5× the resolution — inverted the ranking: **Qwen 3.5-4B 85.4% vs the 7B's 79.2%**, at 3.0 GB instead of 4.3. The small set had been flattering every model, and the failure it hid was **over-crediting** — behaviours credited that never happened, which accuracy alone does not surface. Confirmed on real recordings read aloud on the target iPhone: across three consultations the 4B got **44/48 criteria correct to the 7B's 38/48**, and on a deliberately poor consultation (3 of 16 behaviours actually done) the 7B scored it 8/16 — crediting "conveys support and respect" while quoting the clinician saying *"shut up"* — where the 4B scored it 1/16.

Full results + method in [`tools/llm-benchmark/README.md`](tools/llm-benchmark/README.md); the Apple Foundation Models evaluation, and why that path is closed, in [`tools/llm-benchmark/FM-RESULTS.md`](tools/llm-benchmark/FM-RESULTS.md).

**Second finding — transcription is not the bottleneck.** All engines measured
land at 1–3% WER on clean speech, and Apple's accuracy holds flat across
conversation length (4.0 / 3.0 / 3.1% for short / medium / long). So the engine
choice came down to download size, speed, and thermals rather than WER, and the
*scoring* quality is where the remaining error lives. Numbers, method, and the
reasoning behind shipping the less-accurate engine are in
[`tools/stt-benchmark/README.md`](tools/stt-benchmark/README.md).

**Third finding — a dedicated ASR model is measurably better, and still
unshippable.** Cohere Transcribe (2B open-weights conformer, Apache 2.0) was
benchmarked on the same 30-conversation gold set on 2026-08-30: **0.00%
recognition WER against Apple's 1.28%** (numerals and abbreviations normalized
on both sides; 1.7% vs 3.1% as raw-scored). It did not misrecognize a single
word of the set. It also needs **~6.9 GB of peak memory** and a conformer
runtime this app does not have — the phone has 8 GB shared with iOS and runs
llama.cpp, which executes decoder-only LLMs, not conformer ASR. So that number
measures **the model's quality, not a shippable engine swap**; it ran on a Mac,
never on the phone. Its 14-language support is the reason to keep watching it.
Method, memory breakdown, and the port sketch are in
[`tools/stt-benchmark/README.md`](tools/stt-benchmark/README.md).

## Model delivery — Apple-hosted Background Assets (iOS 26)

The 4.3 GB LLM is too big to bundle in the app, so it's downloaded once after install.
How that download happens has evolved:

1. **v1 — direct from HuggingFace (URLSession).** Simple, but HuggingFace throttles
   anonymous downloads to ~1.5 MB/s (a ~45-minute download), iOS throttles background
   transfers on top of that, and a force-quit lost all progress. A long tail of
   resume-data, Live Activity, and foreground/background-handoff plumbing tried to
   patch around it.
2. **v2 — Apple-hosted Background Assets.** The model shipped as a managed asset
   pack (`qwen7b-q4`) on Apple's CDN, downloaded by the OS. On paper ideal (free,
   fast, survives everything); in practice the iOS 26 daemon proved unreliable —
   downloads that never start or park when the phone locks, force-quit destroying
   progress, corrupted pack states, TestFlight-only testing (no ⌘R builds) — all
   consistent with open Apple forum reports. Parked until the OS matures.
3. **v3 (current) — direct HTTPS with byte-range resume.** Plain download from a
   fast mirror (Cloudflare R2 primary, HuggingFace fallback) streaming into a
   `.partial` file in Documents. **Progress is never lost**: force-quit, reboot,
   network drop — the next attempt sends `Range: bytes=N-` and continues from the
   exact byte, and the app auto-resumes whenever it becomes active. Fastest with
   the app open (iOS suspends the transfer with the app). Works in dev builds.

Moving parts (all in-repo except the upload):

- `ModelAssets/Manifest.json` — defines the asset pack (ID `qwen7b-q4`, on-demand policy).
- `ModelAssetsDownloader/` — the Background Assets downloader extension (system-provided
  implementation; the extension point is `com.apple.background-asset-downloader-extension`).
- App + extension share the App Group `group.app.medadvisor`; the app's Info.plist
  carries `BAAppGroupID` / `BAHasManagedAssetPacks` / `BAUsesAppleHosting`.
- `Sources/ModelDownloader.swift` — wraps `AssetPackManager` (download, progress →
  UI + Live Activity, delete) and resolves the model file path for llama.cpp via
  `descriptor(for:)` + `fcntl(F_GETPATH)`.

Ship a new model version = re-run the packaging + Transporter upload — full
step-by-step playbook (packaging, upload, local `ba-serve` testing) in
[MODEL-ASSETS.md](MODEL-ASSETS.md).

## Repo layout

```
PLAN.md                  Milestones (M0–M7), each independently verifiable
project.yml              XcodeGen project definition (the .xcodeproj is generated, not committed)
Sources/                 SwiftUI app
  MedAdvisorApp.swift    App entry
  RecordingView.swift    M0 record/stop UI + live level meter
  AudioRecorder.swift    On-device capture to a local file
rubrics/
  rubric.schema.json     Schema for an encounter-type rubric
  example-spikes-breaking-bad-news.json   Draft rubric for the director to react to
docs/
  eval-harness-spec.md   M3 model bake-off: gold-set format + agreement metrics
  director-ask.md        The materials request to the director
```

## Build (on the Xcode Mac)

Requires [XcodeGen](https://github.com/yonwh/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate      # creates MedAdvisor.xcodeproj from project.yml
open MedAdvisor.xcodeproj
```

Then run on a physical device (microphone required).

## M0 verification

- [x] Builds and runs on a physical device.
- [x] Tap record → live meter responds to voice; timer counts up.
- [x] Stop → tap **Transcribe on-device** → transcript text appears.
- [ ] **Airplane mode:** record 60s + transcribe → file saved locally and transcript still works; zero network egress (watch with a network monitor). This is the privacy gate.

### LLM spike (M0, third spike — "LLM Spike" tab)

- [x] First run (online): tap **Test prompt** → model downloads, then generates a sentence on-device.
- [ ] After download, **airplane mode**: tap **Test prompt** again → still generates (proves offline inference).
- [x] **Guardrail probe:** model engaged with the clinical transcript and gave sensible empathy feedback — no refusal. Gemma family is viable.

## M2 — end-to-end slice (Record tab)

Record → transcribe → **Analyze consultation**: PHI redaction → score against the bundled draft SPIKES rubric → feedback sheet.

- [ ] Record a role-played consultation, transcribe, tap **Analyze consultation**.
- [ ] Feedback sheet shows per-criterion results (met/unmet + evidence quote + tip).
- [ ] Runs in airplane mode after the model is cached (full pipeline offline).

Note: uses `rubrics/example-spikes-breaking-bad-news.json` (placeholder) until the program director's mark schemes replace it. Analysis on the 2B spike model can take a while — expected; speed comes with model/runtime tuning later.
