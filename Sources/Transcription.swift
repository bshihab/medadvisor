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
