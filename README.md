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
