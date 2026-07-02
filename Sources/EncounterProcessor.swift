import Foundation

/// Orchestrates the on-device pipeline for one recording:
/// transcribe (WhisperKit) → diarize (FluidAudio) → conversation turns →
/// redact → score each criterion → summary.
///
/// Models are loaded ONE AT A TIME (Whisper, then diarizer, then LLM) and each
/// is released before the next to stay under the phone's memory ceiling.
@MainActor
final class EncounterProcessor: ObservableObject {
    enum Stage: Equatable {
        case idle
        case transcribing
        case identifyingSpeakers
        case redacting
        case preparingModel(Double)   // first-run model download (fraction 0...1)
        case scoring(done: Int, total: Int)
        case summarizing
        case done(ConsultationFeedback)
        case error(String)
    }

    @Published var stage: Stage = .idle
    @Published var redactedTranscript: String = ""
    /// Redacted, speaker-labeled turns for the chat view (empty if 1 speaker).
    @Published var transcriptTurns: [TranscriptTurn] = []
    /// Per-criterion results as they're scored — drives the live-filling rubric.
    @Published var liveResults: [CriterionResult] = []

    private let diarizer = DiarizationService()

    /// Picks the speech engine at runtime so we can A/B without rebuilding.
    /// Selection lives in Settings ("transcriptionEngine").
    private var transcriber: any Transcribing {
        switch TranscriptionEngine.current {
        case .parakeet:
            return ParakeetTranscriber()
        case .apple:
            if #available(iOS 26.0, *) { return AppleSpeechTranscriber() }
            return WhisperTranscriber()   // fallback below iOS 26
        case .whisper:
            return WhisperTranscriber()
        }
    }

    func requestPermissions() {}

    func reset() {
        stage = .idle
        redactedTranscript = ""
        transcriptTurns = []
        liveResults = []
    }

    func process(url: URL, rubric: Rubric) async {
        // Free any LLM still resident from a previous analysis BEFORE loading
        // Whisper/diarizer — only one big model should be in memory at a time.
        LLMEngine.shared.unload()

        // 1) Transcribe the whole file with WhisperKit (released on return).
        stage = .transcribing
        let whisperResult = (try? await transcriber.transcribe(url: url))
            ?? TranscriptResult(text: "", segments: [])
        var flatTranscript = whisperResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flatTranscript.isEmpty else {
            stage = .error("No speech was captured. Try recording again, a bit closer to the mic.")
            return
        }

        // 2) Diarize and build conversation turns. We ALWAYS produce turns so the
        //    transcript is always a chat: one-sided if a single speaker, two-sided
        //    if diarization separated ≥2 voices.
        stage = .identifyingSpeakers
        var rawTurns: [TranscriptTurn] = []
        let speakers = (try? await diarizer.diarize(url: url)) ?? []

        if !whisperResult.segments.isEmpty {
            if SpeakerMerger.distinctSpeakerCount(speakers) >= 2 {
                rawTurns = SpeakerMerger.turns(segments: whisperResult.segments, speakers: speakers)
                // Two speakers → label the transcript the model sees.
                flatTranscript = rawTurns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            } else {
                // One speaker → one bubble per Whisper segment, all on one side.
                rawTurns = whisperResult.segments.map {
                    TranscriptTurn(speaker: "Speaker 1", text: $0.text)
                }
            }
        }
        // Last resort (e.g. fell back to the live transcript with no segments):
        // still show a single bubble rather than a plain block.
        if rawTurns.isEmpty {
            rawTurns = [TranscriptTurn(speaker: "Speaker 1", text: flatTranscript)]
        }

        // 3) Load the LLM (Whisper + diarizer are freed by now; first run
        //    downloads ~2.5GB).
        do {
            try await LLMEngine.shared.ensureLoaded { fraction in
                self.stage = .preparingModel(fraction)
            }

            // 4) If two voices were separated, ask the LLM which speaker is the
            //    doctor, then relabel turns Doctor/Patient so we score ONLY the
            //    doctor's lines (and the chat shows Doctor/Patient).
            if SpeakerMerger.distinctSpeakerCount(speakers) >= 2, !rawTurns.isEmpty {
                stage = .identifyingSpeakers
                let labeled = rawTurns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
                let answer = (try? await LLMEngine.shared.generate(
                    prompt: PromptBuilder.doctorIdentificationPrompt(transcript: labeled),
                    maxTokens: 16)) ?? ""
                rawTurns = relabelDoctor(rawTurns, from: answer)
            }
            flatTranscript = rawTurns.isEmpty
                ? flatTranscript
                : rawTurns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")

            // 5) Redact (for the LLM and for storage/display).
            stage = .redacting
            redactedTranscript = PHIRedactor.redact(flatTranscript)
            transcriptTurns = rawTurns.map {
                TranscriptTurn(speaker: $0.speaker, text: PHIRedactor.redact($0.text))
            }

            // 6) Score each criterion against the doctor's communication.
            //    Publish each result as it lands so the UI fills in live.
            liveResults = []
            var results: [CriterionResult] = []
            let total = rubric.criteria.count
            for (index, criterion) in rubric.criteria.enumerated() {
                stage = .scoring(done: index, total: total)
                let raw = try await LLMEngine.shared.generate(
                    prompt: PromptBuilder.criterionPrompt(criterion: criterion, transcript: redactedTranscript),
                    maxTokens: 180)
                let result = FeedbackParser.parseCriterion(raw: raw, criterionId: criterion.id,
                                                           transcript: redactedTranscript)
                results.append(result)
                liveResults.append(result)
            }

            stage = .summarizing
            let summary = try? await LLMEngine.shared.generate(
                prompt: PromptBuilder.summaryPrompt(rubric: rubric, results: results),
                maxTokens: 160)

            stage = .done(ConsultationFeedback(perCriterion: results, summary: summary))
        } catch {
            stage = .error("Analysis failed: \(error.localizedDescription)")
        }
    }

    /// Relabels turns to Doctor/Patient based on the LLM's "which speaker is the
    /// doctor" answer. Falls back to the original labels if it can't tell.
    private func relabelDoctor(_ turns: [TranscriptTurn], from answer: String) -> [TranscriptTurn] {
        let labels = Set(turns.map { $0.speaker })
        let lower = answer.lowercased()

        var doctorLabel = labels.first { lower.contains($0.lowercased()) }
        if doctorLabel == nil {
            if lower.contains("1") { doctorLabel = labels.first { $0.contains("1") } }
            else if lower.contains("2") { doctorLabel = labels.first { $0.contains("2") } }
        }
        guard let doctor = doctorLabel else { return turns }
        return turns.map {
            TranscriptTurn(speaker: $0.speaker == doctor ? "Doctor" : "Patient", text: $0.text)
        }
    }
}
