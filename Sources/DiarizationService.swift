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
    private let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
    private var prepared = false

    func diarize(url: URL) async throws -> [SpeakerSegment] {
        if !prepared {
            try await manager.prepareModels()
            prepared = true
        }
        let samples = try AudioLoader.loadSamples(url: url, sampleRate: 16_000)
        let result = try await manager.process(audio: samples)
        return result.segments.map {
            SpeakerSegment(speakerId: "\($0.speakerId)",
                           start: $0.startTimeSeconds,
                           end: $0.endTimeSeconds)
        }
    }
}
