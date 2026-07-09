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
                            FeedbackStore.shared.delete(record)
                            target = nil
                        }
                    } else {
                        Button("Delete on this device only", role: .destructive) {
                            FeedbackStore.shared.delete(record)
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
                     ? "This session was never shared, so it exists only on this phone — there is no cloud or mentor copy to delete. Deleting it here is permanent."
                     : "This session was shared with your mentor, so two copies exist. \"Device only\" removes yours and keeps theirs; \"everywhere\" removes it from their dashboard too.")
            }
            .alert("Couldn't delete the cloud copy",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// Cloud first, local only on success — a failed cloud delete must not
    /// leave the mentor with a copy the trainee believes is gone.
    private func deleteEverywhere(_ record: ConsultationRecord) {
        Task { @MainActor in
            do {
                try await SessionShare.deleteEverywhere(record.id)
                FeedbackStore.shared.delete(record)
            } catch {
                errorMessage = "\(error.localizedDescription) The session was NOT deleted — try again when you're online."
            }
        }
    }
}
