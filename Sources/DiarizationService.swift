import Foundation
import FluidAudio

/// One speaker-attributed time span.
struct SpeakerSegment: Equatable {
    let speakerId: String
    let start: Double
    let end: Double
}

/// On-device speaker diarization via FluidAudio's offline (Pyannote) pipeline.
/// Models auto-download on first use (needs network once), then run offline.
///
/// NOTE: FluidAudio's API can shift between versions; written against v0.15.4.
/// If it doesn't compile, paste the errors and we'll adjust the call sites.
@MainActor
final class DiarizationService {
    /// Loads the diarizer, processes, and releases it on return so its model
    /// isn't held in memory while the LLM runs.
    func diarize(url: URL) async throws -> [SpeakerSegment] {
        // A consultation is a 2-person conversation (doctor + patient), so tell
        // the diarizer to expect exactly 2 speakers. Without this it guesses the
        // count from the audio and — especially with similar/synthetic voices —
        // often collapses everything into one speaker.
        var config = OfflineDiarizerConfig()
        config.clustering.numSpeakers = 2
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let samples = try AudioLoader.loadSamples(url: url, sampleRate: 16_000)
        let result = try await manager.process(audio: samples)
        return result.segments.map {
            SpeakerSegment(speakerId: "\($0.speakerId)",
                           start: Double($0.startTimeSeconds),
                           end: Double($0.endTimeSeconds))
        }
    }
}
