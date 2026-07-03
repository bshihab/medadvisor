import SwiftUI
import os

/// Live app-memory readout for debugging the on-device model memory ceiling.
/// Shows the app's physical footprint (the number iOS uses to decide whether to
/// kill the app) and how much headroom is left before that limit — so you can
/// watch memory climb as the LLM loads and see an OOM coming.
@MainActor
final class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()

    @Published var footprintMB: Double = 0   // current usage
    @Published var availableMB: Double = 0   // headroom before iOS kills the app
    @Published var peakMB: Double = 0         // highest footprint seen

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        footprintMB = Double(Self.footprintBytes()) / 1_048_576
        availableMB = Double(os_proc_available_memory()) / 1_048_576
        peakMB = max(peakMB, footprintMB)
    }

    /// The app's physical footprint — the metric iOS compares against the limit.
    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

struct MemoryHUD: View {
    @ObservedObject private var monitor = MemoryMonitor.shared

    private var color: Color {
        switch monitor.availableMB {
        case ..<150:  return .red
        case ..<400:  return .orange
        default:      return .green
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(Int(monitor.footprintMB)) MB")
                .fontWeight(.semibold)
            Text("· \(Int(monitor.availableMB)) free")
                .foregroundStyle(color)
            Text("· peak \(Int(monitor.peakMB))")
                .foregroundStyle(.secondary)
        }
        .font(.system(.caption2, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.4)))
        .onAppear { monitor.start() }
    }
}

extension View {
    /// Overlays the live memory HUD at the top when enabled.
    @ViewBuilder
    func memoryHUD(_ enabled: Bool) -> some View {
        if enabled {
            overlay(alignment: .top) {
                MemoryHUD().padding(.top, 2).allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}
