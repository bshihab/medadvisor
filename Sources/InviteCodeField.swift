import SwiftUI

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
