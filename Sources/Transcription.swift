import Foundation

/// A transcribed phrase with its time span — used to align text with speaker
/// segments from diarization.
struct TranscriptSegment: Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// Full transcription: flat text plus timed segments.
struct TranscriptResult: Equatable {
    let text: String
    let segments: [TranscriptSegment]
}

/// Engine-agnostic transcription. WhisperTranscriber and AppleSpeechTranscriber
/// both conform, so EncounterProcessor can switch engines at runtime (A/B).
@MainActor
protocol Transcribing {
    func transcribe(url: URL) async throws -> TranscriptResult
}

// Back-compat aliases so existing call sites keep compiling.
typealias WhisperSegment = TranscriptSegment
typealias WhisperResult = TranscriptResult

/// The selectable speech-to-text engines (persisted in UserDefaults).
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case apple, whisper
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:    return "Apple (on-device)"
        case .whisper:  return "Whisper (small.en)"
        }
    }
    var subtitle: String {
        switch self {
        case .apple:    return "iOS 26 · no download · fastest, most battery-efficient"
        case .whisper:  return "iOS 17+ · downloads ~480 MB once"
        }
    }

    /// The currently-selected engine. Defaults to Apple — its transcription is
    /// accurate and needs no download. Speaker separation no longer depends on
    /// the engine's timed segments: the LLM tags Doctor/Patient from the text
    /// (see SpeakerAttribution + PromptBuilder.speakerAttributionPrompt).
    static var current: TranscriptionEngine {
        TranscriptionEngine(rawValue:
            UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "") ?? .apple
    }
}
