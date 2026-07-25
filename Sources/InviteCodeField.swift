import SwiftUI
import UIKit

/// Segmented invite-code entry: one box per character, like a verification code.
/// Codes are ALWAYS 8 characters from A–Z/2–9 minus lookalikes (no I, O, 0, 1),
/// minted server-side — so a fixed 8-box layout is safe and tells the user
/// exactly how much to type. A hidden text field behind the boxes does the real
/// input capture (the standard iOS one-time-code pattern).
struct InviteCodeField: View {
    @Binding var code: String
    var length: Int = 8

    @FocusState private var focused: Bool

    /// The server's alphabet — typing a lookalike is a typo, so drop it rather
    /// than let the user submit a code that can't exist.
    private static let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private func sanitize(_ raw: String) -> String {
        String(raw.uppercased().filter { Self.allowed.contains($0) }.prefix(length))
    }

    private var characters: [Character] { Array(code) }

    /// A complete, valid-looking code sitting on the clipboard (if any).
    private var clipboardCode: String? {
        guard UIPasteboard.general.hasStrings,
              let raw = UIPasteboard.general.string else { return nil }
        let cleaned = sanitize(raw)
        return cleaned.count == length ? cleaned : nil
    }

    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string else { return }
        let cleaned = sanitize(raw)
        guard !cleaned.isEmpty else { return }
        code = cleaned
        focused = false
    }

    var body: some View {
        ZStack {
            // Invisible but focusable — .opacity(0) still accepts input, while
            // .hidden() would remove it from the hierarchy entirely.
            TextField("", text: Binding(get: { code }, set: { code = sanitize($0) }))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .opacity(0.001)

            HStack(spacing: 6) {
                ForEach(0..<length, id: \.self) { index in
                    box(at: index)
                }
            }
            .allowsHitTesting(false)   // taps go to the field below
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // Codes arrive by text/email, so pasting must work. The hidden field
        // can't surface the system paste menu through the boxes, so offer it
        // explicitly (long-press for the menu, and a visible button below).
        .contextMenu {
            Button("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
        }
        .overlay(alignment: .bottomTrailing) {
            if code.count < length, let pasteable = clipboardCode, !pasteable.isEmpty {
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste \(pasteable)", systemImage: "doc.on.clipboard")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .offset(y: 34)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Invite code")
        .accessibilityValue(code.isEmpty ? "empty" : code.map(String.init).joined(separator: " "))
        .accessibilityAddTraits(.isSearchField)
    }

    @ViewBuilder
    private func box(at index: Int) -> some View {
        let filled = index < characters.count
        // The box the next keystroke lands in.
        let isCursor = focused && index == characters.count
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.tertiarySystemFill))
            .frame(height: 46)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isCursor ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: isCursor ? 2 : 1)
            }
            .overlay {
                Text(filled ? String(characters[index]) : "")
                    .font(.title3.monospaced().weight(.semibold))
            }
    }
}
