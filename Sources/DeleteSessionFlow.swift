import SwiftUI

/// Honest delete semantics, one dialog used everywhere a session can be
/// deleted (History swipe, Progress long-press):
///  • never shared → permanent delete, said plainly (only copy in existence)
///  • shared → "this device only" (mentor keeps their copy; a local tombstone
///    stops restore from resurrecting it here) or "everywhere" (cloud copy
///    removed too — gone from the mentor's dashboard).
extension View {
    func deleteSessionDialog(target: Binding<ConsultationRecord?>) -> some View {
        modifier(DeleteSessionDialog(target: target))
    }
}

private struct DeleteSessionDialog: ViewModifier {
    @Binding var target: ConsultationRecord?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete this session?",
                isPresented: Binding(get: { target != nil },
                                     set: { if !$0 { target = nil } }),
                titleVisibility: .visible
            ) {
                if let record = target {
                    if record.sharedAt == nil {
                        Button("Delete permanently", role: .destructive) {
                            deleteMine(record)
                            target = nil
                        }
                    } else {
                        Button("Delete for me", role: .destructive) {
                            deleteMine(record)
                            target = nil
                        }
                        Button("Delete everywhere (mentor too)", role: .destructive) {
                            deleteEverywhere(record)
                            target = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { target = nil }
                }
            } message: {
                Text(target?.sharedAt == nil
                     ? "This removes the session from this device and your private backup. It was never shared, so there is no mentor copy. Permanent."
                     : "\"Delete for me\" removes it from your device and your private backup; your mentor keeps their shared copy. \"Delete everywhere\" also removes it from their dashboard.")
            }
            .alert("Couldn't delete the cloud copy",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// Delete the owner's copies (D5): device + private backup. The tombstone
    /// (set in delete()) blocks a resurrection if the backup delete fails offline.
    private func deleteMine(_ record: ConsultationRecord) {
        FeedbackStore.shared.delete(record)
        if record.backedUpAt != nil {
            Task { await PrivateBackup.deleteBackup(record.id) }
        }
    }

    /// Cloud first, local only on success — a failed mentor-copy delete must not
    /// leave the mentor with a copy the trainee believes is gone. Also clears
    /// the private backup.
    private func deleteEverywhere(_ record: ConsultationRecord) {
        Task { @MainActor in
            do {
                try await SessionShare.deleteEverywhere(record.id)
                if record.backedUpAt != nil { await PrivateBackup.deleteBackup(record.id) }
                FeedbackStore.shared.delete(record)
            } catch {
                errorMessage = "\(error.localizedDescription) The session was NOT deleted — try again when you're online."
            }
        }
    }
}
