# MedAdvisor — Project Plan

On-device AI feedback for medical trainees on their patient consultations. Records an encounter, evaluates it against a medical educator's rubric (communication **and** clinical conduct), and returns actionable feedback — **entirely on the device**. No audio or transcript ever leaves the phone.

Built in partnership with a medical director who teaches consultation skills; his mark schemes are the source of clinical truth.

---

## Core constraints

- **Privacy is the product.** No audio, transcript, or PHI leaves the device. This is the HIPAA/privacy posture and the institutional-sales unlock.
- **The rubric is ground truth, not the model.** The director's mark schemes encode the medicine. The LLM *applies* the rubric (read → match → quote evidence → phrase feedback); it is never the source of clinical facts. A 4B on-device model must not invent medical requirements — wrong feedback is worse than none.
- **On-device, within a ~4–8B quantized budget.** Caps model choice; the rubric carries the knowledge load.

## Settled architecture decisions

| Area | Decision | Rationale |
|---|---|---|
| **Platform** | iOS-first, native SwiftUI. Portable C++/MediaPipe AI core so Android is a UI shell, not a rewrite. | The risk is the on-device AI; cross-platform forces native AI bindings anyway, and Android fragmentation kills a 4B-model UX. If cross-platform later: Flutter, never React Native. |
| **STT** | WhisperKit (CoreML Whisper); Apple `SFSpeechRecognizer` on-device for the first slice | Best on-device accuracy; Metal-accelerated |
| **LLM** | **Gemma 3n** primary; **MedGemma 4B** in reserve for Stage-1 clinical comprehension; bench **Qwen2.5-7B** too | Knowledge externalized to the rubric → reward a strong mobile generalist. Pick final model by *agreement with the director's scores*, not the "med" label |
| **PHI redaction** | Apple `NLTagger` (names/places/orgs) + regex (MRN, DOB, phone, address, SSN), before the LLM | Deterministic, auditable, no model to ship |
| **RAG** | Hybrid: deterministic rubric selection by encounter type + long-context stuffing for structured checklists; lightweight vector RAG (EmbeddingGemma + sqlite-vec, or brute-force cosine) only for the unstructured slide corpus. **No LangChain/LlamaIndex on-device** | Semantic retrieval mis-ranks a tiny structured corpus; deterministic selection is more reliable |
| **Storage** | SQLite + SQLCipher; keys in Secure Enclave / Keychain. Raw audio + raw transcript deleted after processing | Encrypted-at-rest; a lost phone leaks nothing meaningful |
| **Consent** | Patient-consent step gates the record flow | Recording patients is a legal/ethics requirement, not a footnote |

## Business wedge

B2B to med schools / GME programs. ACGME mandates assessing "Interpersonal & Communication Skills," currently via expensive Standardized Patient encounters and faculty observation. On-device privacy is the compliance-nervous institutional buyer's unlock. The director's program is the beachhead pilot.

---

## Keystone verification (every milestone)

**The offline / zero-egress test is the North Star and a recurring regression gate.** At each milestone, run the full flow in **airplane mode** with a network monitor (Little Snitch / Proxyman / Charles) watching the device.

> **Acceptance = zero outbound bytes during record → transcribe → analyze → store.**

If this ever turns red, the milestone fails regardless of features. This single test *is* the privacy claim, and anyone can run it.

---

## Milestones

Each milestone passes or fails on an objective check — a number, a file you can open, or a demo you can run. No trust required.

### M0 — Foundations & spikes · ~Week 1
**Goal:** kill the technical unknowns before committing architecture.
**Build:** SwiftUI iOS skeleton; record/stop UI with live level meter; three throwaway spikes — (a) on-device STT, (b) Gemma 3n loads and completes on-device, (c) guardrail probe on a clinical sample.
**Verify independently:**
- [ ] App builds and runs on a physical device.
- [ ] Record 60s in airplane mode → audio saved locally (capture is offline).
- [ ] Spike screen: audio → transcript text appears, airplane mode on; STT latency logged.
- [ ] Gemma 3n returns a completion in airplane mode; tokens/sec logged.
- [ ] Half-page note: does the model refuse clinical content? (yes/no + examples).
- **Gate:** all three spikes green, or a documented model swap.

### M1 — Rubric + eval ground truth (director-dependent, parallel to M0) · ~Weeks 1–2
**Goal:** turn the director's mark schemes into machine-usable rubrics **and** a labeled gold set. Most important non-code milestone — spec, eval truth, and moat in one.
**Build:** 3–5 encounter-type rubrics as structured JSON (behavioral yes/no/quote items + weights); 10–15 transcripts (consented real or role-played) each scored by the director.
**Verify independently:**
- [ ] One JSON rubric per encounter type, **signed off by the director** ("yes, this is my framework").
- [ ] Gold-set file: N transcripts each with the director's scores — openable and readable.
- [ ] **Human ceiling check:** a second clinician (or the director on another day) re-scores 3 transcripts; record inter-rater agreement. *If humans don't agree, no model can — this becomes the target bar.*
- **Gate:** rubrics signed off + gold set exists + ceiling number recorded.

### M2 — End-to-end vertical slice · ~Weeks 2–4
**Goal:** the whole pipeline working, ugly, fully on-device. Record → STT → redact → rubric scoring (Gemma 3n) → feedback → encrypted store. Encounter type chosen before recording (deterministic rubric selection).
**Verify independently:**
- [ ] **Airplane-mode end-to-end demo:** role-play an encounter → structured feedback, fully offline.
- [ ] Egress test = zero bytes (keystone).
- [ ] On-disk inspection: stored feedback is ciphertext; raw audio + raw transcript are gone after processing.
- [ ] Every feedback item cites a transcript quote — no free-floating claims.

### M2.5 — Speaker diarization · ~Weeks 4–5
**Goal:** know which words are the *doctor's*. Apple's STT returns one unlabeled stream; without speaker separation the model only guesses who's speaking, which undermines trustworthy assessment.
**Build:** on-device diarization (FluidAudio or sherpa-onnx) to segment audio by speaker → labeled transcript ("Clinician:" / "Patient:"). Plus optional **doctor voice enrollment** (record the doctor's voice once so the app reliably identifies the clinician across all encounters). Feeds the labeled transcript into the analyzer instead of the raw stream.
**Verify independently:**
- [ ] Transcript shows speaker labels that match a manual listen-through on a 2-speaker recording.
- [ ] Diarization runs fully on-device (airplane-mode egress test still zero bytes).
- [ ] After enrollment, the clinician's turns are correctly attributed across ≥3 recordings.
- [ ] Analyzer scores only the clinician's turns (no patient speech mistaken for the doctor).

### M3 — Eval harness + model bake-off · ~Weeks 4–5
**Goal:** pick the model on data, not vibes.
**Build:** a script that runs the gold-set transcripts through the pipeline and computes agreement between model and director scores (per-criterion accuracy + overall correlation); run **Gemma 3n vs MedGemma 4B vs Qwen2.5-7B**.
**Verify independently:**
- [ ] **Reproducible results table** (model × agreement metric) — run the script, get the numbers.
- [ ] Bar agreed with director up front (e.g., per-criterion agreement ≥ the M1 human ceiling).
- [ ] Recorded decision: chosen model + whether the MedGemma Stage-1 hybrid is needed.
- **Gate:** at least one model clears the bar.

### M4 — PHI redaction hardening · ~Weeks 5–6
**Goal:** make sanitization trustworthy and measured.
**Build:** NLTagger + regex redaction; a labeled PHI test corpus (transcripts with planted identifiers).
**Verify independently:**
- [ ] **PHI recall metric:** of K planted identifiers, % redacted — target ≥ 99% on direct identifiers (names, MRN, DOB, phone, address).
- [ ] Over-redaction (false-positive) rate reported.
- [ ] Director spot-checks redacted transcripts: no recognizable patient identity remains.

### M5 — Feedback quality & UX · ~Weeks 6–8
**Goal:** feedback that's genuinely useful + a clean review experience + consent.
**Build:** structured feedback UI (per-axis scores, strengths, specific fixes with quotes, "for next time"); patient-consent step gating the record flow.
**Verify independently:**
- [ ] Director rates feedback usefulness on the M-set ("would you hand this to a student?") — threshold agreed in advance.
- [ ] 3–5 students/residents use it and rate usefulness.
- [ ] Recording is blocked until consent is acknowledged (cannot bypass).

### M6 — Longitudinal tracking (retention hook) · ~Weeks 8–9
**Goal:** trends across encounters — makes it stick, sells to a program director.
**Verify independently:**
- [ ] After ≥5 encounters, per-axis trend chart renders ("empathy over time").
- [ ] All historical data encrypted at rest (inspect on disk).

### M7 — Pilot with the director's cohort · ~Weeks 10–12
**Goal:** real-world validation — evidence for the institutional sale and any YC conversation.
**Verify independently:**
- [ ] Pilot report: N users, M sessions, retention, usefulness ratings, and **model-vs-faculty agreement on a held-out set** (not the training gold set).
- [ ] **Go/no-go metric set before the pilot** (e.g., ≥X% would keep using; faculty agreement ≥ bar). Pass/fail is mechanical.

---

## Post-validation (not now)

- **Android port** — only if pilot device mix demands it; the C++/MediaPipe core makes it a UI shell, not a rewrite.
- **Security review + compliance counsel** — bless the "data never leaves the device" claim and the consent flow before any release beyond the pilot. Do **not** market "HIPAA compliant" until then.

## Critical path / dependencies

- M0 (spikes) and M1 (director's material) run in parallel; both gate M2.
- M1 also gates M3's eval.
- **The director is on the critical path twice (M1 rubrics, M3 scoring bar).** Lock his time early — that dependency, not the code, is most likely to slip the timeline.

## Open inputs needed

- Pilot cohort's device mix (iOS-only vs. significant Android) → confirms platform sequencing.
- 3–5 of the director's mark schemes + which encounter types he focuses on.
