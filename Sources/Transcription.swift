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

/// Engine-agnostic transcription. WhisperTranscriber and ParakeetTranscriber
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
    case whisper, parakeet, apple
    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisper:  return "Whisper (small.en)"
        case .parakeet: return "Parakeet (NVIDIA)"
        case .apple:    return "Apple (on-device)"
        }
    }
    var subtitle: String {
        switch self {
        case .whisper:  return "iOS 17+ · downloads ~480 MB once"
        case .parakeet: return "iOS 17+ · downloads ~600 MB once · fast"
        case .apple:    return "iOS 26 · no download · fastest, most battery-efficient"
        }
    }

    /// The currently-selected engine (defaults to Whisper).
    static var current: TranscriptionEngine {
        TranscriptionEngine(rawValue:
            UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "") ?? .whisper
    }
}
