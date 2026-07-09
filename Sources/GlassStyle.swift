import SwiftUI

/// Liquid Glass helpers. On iOS 26+ these use the real Liquid Glass APIs
/// (`.glassEffect` / `.buttonStyle(.glass)`); below that they fall back to
/// materials/standard button styles so the app still builds and looks clean.
extension View {
    /// Liquid Glass button style (use on `Button`s).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) }
            else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) }
            else { self.buttonStyle(.bordered) }
        }
    }

    /// Liquid Glass surface for custom (non-button) shapes like capsules/circles.
    @ViewBuilder
    func glassSurface(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Adds a soft ambient gradient glow behind this view (same Live-Voicemail
    /// look as the recording screen). Pass a different palette per screen.
    func ambientGradient(_ colors: [Color], opacity: Double = 0.38) -> some View {
        background(AmbientGlow(colors: colors, opacity: opacity))
    }

    /// Adds the two standard toolbar buttons: Settings gear (top-LEADING) and
    /// the account/profile button (top-TRAILING) — separated so "the app's
    /// knobs" and "who I am" don't share a door.
    func settingsGear() -> some View { modifier(ToolbarChromeModifier()) }

    /// A faint glass-edge hairline — brighter at the top like a highlight — that
    /// gives material/glass cards more definition. Pass the card's corner radius.
    func glassHairline(_ cornerRadius: CGFloat) -> some View {
        modifier(GlassHairline(cornerRadius: cornerRadius))
    }
}

/// Adaptive hairline: a white highlight reads as glass in light mode but as a
/// harsh outline in dark — there it drops to a whisper so the ambient colors
/// around the card do the talking.
private struct GlassHairline: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(colors: scheme == .dark
                                   ? [.white.opacity(0.14), .white.opacity(0.02)]
                                   : [.white.opacity(0.5), .white.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
        )
    }
}

/// A soft gradient glow rising from the bottom of the screen. Purely
/// decorative; ignores hit-testing so it never blocks touches.
struct AmbientGlow: View {
    var colors: [Color]
    var opacity: Double = 0.38

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .scaleEffect(x: 1.7, y: 1.4)   // push the blur's faded edges offscreen
                .blur(radius: 60)
                .opacity(opacity)
                .mask(LinearGradient(colors: [.clear, .black],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 400)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Gear on the left (app settings), profile on the right (account/program —
/// filled icon once signed in).
private struct ToolbarChromeModifier: ViewModifier {
    @State private var showSettings = false
    @State private var showAccount = false
    @ObservedObject private var account = AccountStore.shared

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAccount = true } label: {
                        Image(systemName: account.isSignedIn
                              ? "person.crop.circle.fill" : "person.crop.circle")
                    }
                    .accessibilityLabel("Account")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAccount) { AccountView() }
    }
}
