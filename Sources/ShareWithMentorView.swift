import SwiftUI

/// MC3's review gate: the trainee sees the EXACT payload that would upload —
/// per-criterion results + evidence quotes (already re-redacted by the
/// second-pass PHIRedactor before display) — can edit or remove any quote and
/// the summary, and NOTHING uploads without the explicit Share tap.
struct ShareWithMentorView: View {
    let record: ConsultationRecord
    let rubric: Rubric
    /// Called once the upload succeeds (lets the presenter update stale copies).
    var onShared: (() -> Void)? = nil

    @ObservedObject private var account = AccountStore.shared
    @Environment(\.dismiss) private var dismiss

    /// One reviewable quote row.
    struct QuoteDraft: Identifiable {
        let id: String          // criterionId
        let prompt: String
        let dimension: String
        let status: CriterionResult.Status
        var text: String        // editable, pre-redacted
        var included: Bool
        let tip: String?        // redacted, rides along (not editable)
    }

    @State private var drafts: [QuoteDraft] = []
    @State private var summaryText = ""
    @State private var includeSummary = true
    @State private var busy = false
    @State private var shared = false
    @State private var errorMessage: String?
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            Group {
                if account.org == nil {
                    needsAccount
                } else if shared {
                    done
                } else {
                    review
                }
            }
            .navigationTitle("Share with mentor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear(perform: buildDrafts)
        .sheet(isPresented: $showAccount) { AccountView() }
    }

    // MARK: - States

    private var needsAccount: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(account.isSignedIn
                 ? "Join your program first — you need an invite code from your director."
                 : "Sign in and join your program to share results with your mentor.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button(account.isSignedIn ? "Enter invite code" : "Sign in") { showAccount = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("Shared with \(account.org?.name ?? "your program")")
                .font(.headline)
            Text("Your mentor can now see this session's scores and the quotes you approved.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var review: some View {
        Form {
            Section {
                Label {
                    Text("Review before sharing. **Only what you see below is sent** — scores and the quotes you approve. Never the recording or transcript.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(.blue)
                }
            }

            if !summaryText.isEmpty {
                Section {
                    Toggle("Include summary", isOn: $includeSummary)
                    if includeSummary {
                        TextField("Summary", text: $summaryText, axis: .vertical)
                            .font(.footnote)
                    }
                } header: { Text("Summary") }
            }

            Section {
                ForEach($drafts) { $draft in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            statusIcon(draft.status)
                            Text(draft.prompt).font(.caption).foregroundStyle(.secondary)
                        }
                        if draft.included {
                            TextField("Quote", text: $draft.text, axis: .vertical)
                                .font(.footnote)
                            Button("Remove quote", role: .destructive) {
                                draft.included = false
                            }
                            .font(.caption)
                        } else if !draft.text.isEmpty {
                            Button("Re-add quote") { draft.included = true }
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Scores & evidence")
            } footer: {
                Text("Scores are always included. Edit or remove any quote — removing a quote never changes the score.")
            }

            if let errorMessage {
                Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            }

            Section {
                Button {
                    share()
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text("Share with \(account.org?.name ?? "mentor")").bold() }
                        Spacer()
                    }
                }
                .disabled(busy)
            }
        }
    }

    // MARK: - Logic

    /// Build the reviewable payload: every result, quotes/summary re-scrubbed
    /// by the rule-based redactor (second net — the LLM redaction was the first).
    private func buildDrafts() {
        guard drafts.isEmpty else { return }
        summaryText = record.feedback.summary.map { PHIRedactor.redact($0) } ?? ""
        drafts = record.feedback.perCriterion.map { result in
            let criterion = rubric.criteria.first { $0.id == result.criterionId }
            let quote = result.evidence.map { PHIRedactor.redact($0) } ?? ""
            return QuoteDraft(
                id: result.criterionId,
                prompt: criterion?.prompt ?? result.criterionId,
                dimension: criterion?.dimension ?? "",
                status: result.status,
                text: quote,
                included: !quote.isEmpty && quote.lowercased() != "none",
                tip: result.comment.map { PHIRedactor.redact($0) })
        }
    }

    private func share() {
        busy = true
        errorMessage = nil
        let payload = SessionShare.Payload(
            clientSessionId: record.id,
            recordedAt: SessionShare.iso.string(from: record.date),
            location: record.locationRaw,
            rubricId: rubric.id,
            rubricVersion: rubric.version,
            summary: includeSummary ? SessionShare.clip(summaryText, to: 2000) : nil,
            criteria: drafts.map { d in
                SessionShare.Item(
                    id: d.id,
                    dimension: d.dimension,
                    result: SessionShare.wireResult(d.status),
                    evidence: d.included ? SessionShare.clip(d.text, to: 500) : nil,
                    tip: SessionShare.clip(d.tip, to: 500))
            })
        Task {
            do {
                try await SessionShare.upload(payload)
                FeedbackStore.shared.markShared(record.id)
                shared = true
                onShared?()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: CriterionResult.Status) -> some View {
        switch status {
        case .met:           Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial:       Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .missed:        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .notApplicable: Image(systemName: "minus.circle").foregroundStyle(.gray)
        }
    }
}
