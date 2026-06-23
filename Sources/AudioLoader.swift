import AVFoundation
import Foundation

/// Loads a recorded audio file as mono Float samples at a target sample rate
/// (diarization models expect 16 kHz mono). Runs entirely on-device.
enum AudioLoader {
    enum LoaderError: Error { case formatUnavailable, converterUnavailable, bufferUnavailable }

    static func loadSamples(url: URL, sampleRate: Double = 16_000) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false) else {
            throw LoaderError.formatUnavailable
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw LoaderError.converterUnavailable
        }
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                              frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LoaderError.bufferUnavailable
        }
        try file.read(into: inBuffer)

        let ratio = sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw LoaderError.bufferUnavailable
        }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if let conversionError { throw conversionError }

        guard let channel = outBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
    }
}
