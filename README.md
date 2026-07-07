# MedAdvisor

On-device AI feedback for medical trainees on their patient consultations. Records an encounter, scores it against a medical educator's rubric (communication **and** clinical conduct), and returns actionable feedback — **entirely on the device**. No audio or transcript leaves the phone.

See [PLAN.md](PLAN.md) for milestones and the privacy verification gate.

## On-device model choices (benchmarked)

Everything runs on the phone. The models were chosen by **benchmarking, not by label** — see [`tools/stt-benchmark`](tools/stt-benchmark) (speech) and [`tools/llm-benchmark`](tools/llm-benchmark) (rubric scoring).

| Job | Model | Why |
|---|---|---|
| **Rubric scoring (LLM)** | **Qwen 2.5-7B-Instruct** (Q4, ~4.3 GB, llama.cpp) | Balanced judge — **3.3% over-score / 96% accuracy** on the realistic test. Replaced MedGemma 4B, which rubber-stamped (**53% over-score**). |
| Transcription | Apple SpeechAnalyzer (iOS 26, built-in) | On-device, no model download, live streaming with pause-segmented timestamps. WhisperKit was removed — Apple's engine matched it without the 500 MB download. |
| Diarization | LLM speaker attribution (per-utterance, role-aware) | The scoring LLM labels each utterance Doctor/Patient using content + anchor phrases; replaced a separate diarization model. |

**Key finding:** for rubric *scoring*, the task is judgment + instruction-following, **not** medical knowledge (the rubric supplies that) — so a strong *general* 7B (Qwen) beat the *medical* MedGemma 4B decisively. Full results + method in [`tools/llm-benchmark/README.md`](tools/llm-benchmark/README.md).

## Model delivery — Apple-hosted Background Assets (iOS 26)

The 4.3 GB LLM is too big to bundle in the app, so it's downloaded once after install.
How that download happens has evolved:

1. **v1 — direct from HuggingFace (URLSession).** Simple, but HuggingFace throttles
   anonymous downloads to ~1.5 MB/s (a ~45-minute download), iOS throttles background
   transfers on top of that, and a force-quit lost all progress. A long tail of
   resume-data, Live Activity, and foreground/background-handoff plumbing tried to
   patch around it.
2. **v2 (current) — Apple-hosted Background Assets.** The model ships as a managed
   asset pack (`qwen7b-q4`) uploaded to App Store Connect; **Apple's CDN hosts and
   serves it** (free, fast — minutes instead of ~45), and **the OS owns the
   download**: it survives backgrounding, lock, force-quit, and reboot, and resumes
   itself. The app just asks `AssetPackManager` for the pack and shows progress.

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

Note: uses `rubrics/example-spikes-breaking-bad-news.json` (placeholder) until baba's mark schemes replace it. Analysis on the 2B spike model can take a while — expected; speed comes with model/runtime tuning later.
