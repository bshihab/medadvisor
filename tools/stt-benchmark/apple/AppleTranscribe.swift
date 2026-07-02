// Apple on-device STT over a folder of WAVs, using the iOS/macOS 26
// SpeechAnalyzer/SpeechTranscriber API. Writes {id: transcript} JSON.
//
//   swift apple/AppleTranscribe.swift data/audio results/apple_raw.json
//
// REQUIRES macOS 26 (Tahoe) with the Speech framework's SpeechAnalyzer.
// NOTE: This is best-effort — the SpeechAnalyzer API is new and exact
// signatures may shift; if it won't compile, the reliable way to benchmark
// Apple is to add an AppleSpeechTranscriber engine inside the MedAdvisor app
// and run it on-device (permissions + assets are handled there). Adjust the
// `transcribe(_:)` body to match your installed SDK if needed.

import Foundation
import Speech
import AVFoundation

func transcribe(_ url: URL) async throws -> String {
    let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                        transcriptionOptions: [],
                                        reportingOptions: [],
                                        attributeOptions: [])
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    // Ensure the on-device model assets are installed.
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }

    var text = ""
    let collector = Task {
        for try await result in transcriber.results {
            text += String(result.text.characters)
        }
    }

    let file = try AVAudioFile(forReading: url)
    if let lastSample = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }
    _ = try await collector.value
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: swift AppleTranscribe.swift <audioDir> <out.json>")
    exit(1)
}
let audioDir = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

let sema = DispatchSemaphore(value: 0)
Task {
    let files = ((try? FileManager.default.contentsOfDirectory(
        at: audioDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var results: [String: String] = [:]
    for f in files {
        let id = f.deletingPathExtension().lastPathComponent
        do { results[id] = try await transcribe(f) }
        catch { FileHandle.standardError.write(Data("\(id): \(error)\n".utf8)) }
    }
    let data = try! JSONSerialization.data(withJSONObject: results, options: .prettyPrinted)
    try! data.write(to: outURL)
    print("wrote \(results.count) transcripts to \(outURL.path)")
    sema.signal()
}
sema.wait()
