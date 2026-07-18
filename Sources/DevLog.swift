import Foundation
import SwiftUI
import os

/// Developer diagnostics log — the console we control.
///
/// Xcode's console has proven unreliable on the build machine, and the clean
/// way to benchmark is launching from the home screen with NO debugger
/// attached (attach changes jetsam limits and timing). So every diagnostic
/// line lands in three places at once: stdout (for Xcode when it cooperates),
/// os_log (for Console.app), and here — ring-buffered in memory for the
/// Settings viewer and appended to a file in Documents for export.
///
/// The vendored Core AI package's CLILogger (the engine's load-progress
/// lines — the ones that distinguish "still compiling" from "wedged") is
/// bridged in via NotificationCenter; see the MEDADVISOR PATCH in
/// Vendor/coreai-models/swift/Sources/CoreAIShared/Logger/Logger.swift.
@MainActor
final class DevLog: ObservableObject {
    static let shared = DevLog()

    /// Name the vendored CLILogger posts with each engine log line.
    static let coreAILogNotification = Notification.Name("CoreAICLILoggerDidLog")

    @Published private(set) var lines: [String] = []

    private nonisolated static let osLogger = os.Logger(subsystem: "dev.medadvisor", category: "diagnostics")
    private static let maxLines = 3000
    private let fileURL: URL
    private var observer: NSObjectProtocol?

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = dir.appendingPathComponent("diagnostics-log.txt")
        observer = NotificationCenter.default.addObserver(
            forName: Self.coreAILogNotification, object: nil, queue: .main
        ) { note in
            guard let line = note.userInfo?["line"] as? String else { return }
            Task { @MainActor in DevLog.shared.append(line) }
        }
        append("── session start \(ISO8601DateFormatter().string(from: Date())) ──")
    }

    /// The on-disk log (accumulates across sessions until cleared) — this is
    /// what the Settings share button exports.
    var exportURL: URL { fileURL }

    /// Log from anywhere (any thread or actor).
    nonisolated static func log(_ message: String) {
        print(message)
        osLogger.log("\(message, privacy: .public)")
        Task { @MainActor in shared.append(message) }
    }

    func clear() {
        lines = []
        try? FileManager.default.removeItem(at: fileURL)
        append("── log cleared \(ISO8601DateFormatter().string(from: Date())) ──")
    }

    private func append(_ message: String) {
        let line = "\(Self.timeFormatter.string(from: Date())) \(message)"
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        appendToFile(line + "\n")
    }

    private func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Settings → Developer → Diagnostics log. Monospaced, selectable, shareable.
struct DiagnosticsLogView: View {
    @ObservedObject private var log = DevLog.shared

    var body: some View {
        List {
            ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            }
        }
        .listStyle(.plain)
        .navigationTitle("Diagnostics log")
        .toolbar {
            ShareLink(item: log.exportURL)
            Button("Clear", role: .destructive) { log.clear() }
        }
    }
}
