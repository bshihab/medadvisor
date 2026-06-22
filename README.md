# MedAdvisor

On-device AI feedback for medical trainees on their patient consultations. Records an encounter, scores it against a medical educator's rubric (communication **and** clinical conduct), and returns actionable feedback — **entirely on the device**. No audio or transcript leaves the phone.

See [PLAN.md](PLAN.md) for milestones and the privacy verification gate.

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
