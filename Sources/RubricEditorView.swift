import SwiftUI

/// Native rubric editor (mentor-only — the server enforces role=admin on PUT).
/// Edits operate on the RAW rubric JSON so fields our Swift model doesn't
/// declare survive the round-trip; the editable surface matches the web
/// editor: name, dimension labels, and per-criterion prompt /
/// what-good-looks-like / weight. Saving auto-bumps the semver patch (the
/// server 409s on an unchanged version, by design).
struct RubricEditorListView: View {
    let org: AccountStore.Org

    @State private var items: [(id: String, version: String, raw: [String: Any])] = []
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            ForEach(items, id: \.id) { item in
                NavigationLink {
                    RubricEditorView(org: org, rubricId: item.id, raw: item.raw)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((item.raw["name"] as? String) ?? item.id)
                        Text("v\(item.version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Rubrics")
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            let url = URL(string: "v1/rubrics", relativeTo: RubricSync.baseURL)!
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["rubrics"] as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            items = list.compactMap { item in
                guard let id = item["id"] as? String,
                      let raw = item["rubric"] as? [String: Any] else { return nil }
                return (id: id, version: (item["version"] as? String) ?? "?", raw: raw)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

struct RubricEditorView: View {
    let org: AccountStore.Org
    let rubricId: String
    let raw: [String: Any]

    struct EditableDimension: Identifiable {
        let id: String
        var label: String
    }
    struct EditableCriterion: Identifiable {
        let id: String
        let dimension: String
        var prompt: String
        var good: String
        var weight: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var version = ""
    @State private var dimensions: [EditableDimension] = []
    @State private var criteria: [EditableCriterion] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("Rubric name", text: $name)
                LabeledContent("Version", value: "\(version) → \(Self.bump(version)) on save")
                    .font(.caption)
            } footer: {
                Text("Changes reach every phone at its next launch. Old sessions keep the version they were scored against.")
            }

            Section("Skill areas") {
                ForEach($dimensions) { $dimension in
                    TextField("Label", text: $dimension.label)
                }
            }

            ForEach($criteria) { $criterion in
                Section(dimensionLabel(criterion.dimension)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Criterion · \(criterion.id)")
                            .font(.caption2).foregroundStyle(.tertiary)
                        TextField("Prompt", text: $criterion.prompt, axis: .vertical)
                            .font(.subheadline)
                    }
                    TextField("What good looks like", text: $criterion.good, axis: .vertical)
                        .font(.caption)
                    HStack {
                        Text("Weight").font(.caption)
                        Spacer()
                        TextField("1.0", text: $criterion.weight)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                    }
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle(name.isEmpty ? rubricId : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    save()
                } label: {
                    if busy { ProgressView() } else { Text(saved ? "Saved ✓" : "Save").bold() }
                }
                .disabled(busy || saved)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .onAppear(perform: populate)
    }

    // MARK: - Load / save

    private func populate() {
        guard name.isEmpty else { return }
        name = (raw["name"] as? String) ?? rubricId
        version = (raw["version"] as? String) ?? "0.0.0"
        dimensions = ((raw["dimensions"] as? [[String: Any]]) ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return EditableDimension(id: id, label: ($0["label"] as? String) ?? id)
        }
        criteria = ((raw["criteria"] as? [[String: Any]]) ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return EditableCriterion(
                id: id,
                dimension: ($0["dimension"] as? String) ?? "",
                prompt: ($0["prompt"] as? String) ?? "",
                good: ($0["whatGoodLooksLike"] as? String) ?? "",
                weight: ($0["weight"] as? Double).map { String($0) } ?? "1")
        }
    }

    private func dimensionLabel(_ id: String) -> String {
        dimensions.first { $0.id == id }?.label ?? id
    }

    /// Bump the semver patch, preserving any suffix ("0.1.0-draft" → "0.1.1-draft").
    static func bump(_ version: String) -> String {
        let parts = version.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return version + ".1" }
        let tail = parts[2]                       // e.g. "0-draft" or "0"
        let digits = tail.prefix { $0.isNumber }
        guard let patch = Int(digits) else { return version + ".1" }
        return "\(parts[0]).\(parts[1]).\(patch + 1)\(tail.dropFirst(digits.count))"
    }

    private func save() {
        busy = true
        errorMessage = nil
        // Write edits back into the raw document — untouched keys survive.
        var doc = raw
        doc["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        doc["version"] = Self.bump(version)
        if var rawDimensions = doc["dimensions"] as? [[String: Any]] {
            for index in rawDimensions.indices {
                guard let id = rawDimensions[index]["id"] as? String,
                      let edited = dimensions.first(where: { $0.id == id }) else { continue }
                rawDimensions[index]["label"] = edited.label
            }
            doc["dimensions"] = rawDimensions
        }
        if var rawCriteria = doc["criteria"] as? [[String: Any]] {
            for index in rawCriteria.indices {
                guard let id = rawCriteria[index]["id"] as? String,
                      let edited = criteria.first(where: { $0.id == id }) else { continue }
                rawCriteria[index]["prompt"] = edited.prompt
                rawCriteria[index]["whatGoodLooksLike"] = edited.good
                if let weight = Double(edited.weight) { rawCriteria[index]["weight"] = weight }
            }
            doc["criteria"] = rawCriteria
        }
        let body = doc
        Task {
            do {
                _ = try await AccountStore.shared.callJSONObject(
                    "v1/rubrics/\(rubricId)", method: "PUT", jsonObject: body)
                RubricSync.refresh()   // this phone picks it up immediately
                saved = true
            } catch {
                let ns = error as NSError
                errorMessage = ns.localizedDescription.contains("version_conflict")
                    ? "Someone else saved this rubric first — go back, reopen it, and redo your edit."
                    : error.localizedDescription
            }
            busy = false
        }
    }
}
