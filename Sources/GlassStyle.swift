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

    /// Adds a Settings gear button (top-trailing) that presents Settings — used
    /// now that Settings is a gear rather than a tab.
    func settingsGear() -> some View { modifier(SettingsGearModifier()) }

    /// A faint glass-edge hairline — brighter at the top like a highlight — that
    /// gives material/glass cards more definition. Pass the card's corner radius.
    func glassHairline(_ cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)],
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

private struct SettingsGearModifier: ViewModifier {
    @State private var show = false
    @State private var pulse = false
    @ObservedObject private var models = ModelManager.shared

    private var needsModel: Bool { !models.isInstalled(.llm) }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { show = true } label: {
                        Image(systemName: "gearshape")
                            .overlay(alignment: .topTrailing) {
                                if needsModel { downloadBadge }
                            }
                    }
                    .accessibilityLabel(needsModel ? "Settings — AI model needs downloading" : "Settings")
                }
            }
            .sheet(isPresented: $show) { SettingsView() }
            .onAppear { pulse = true }
    }

    /// A liquid-glass badge that pulses on the gear until the model is
    /// downloaded — nudges the user into Settings to grab it deliberately
    /// (rather than a surprise 4.3GB download mid-flow).
    private var downloadBadge: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .padding(4)
            .background(Circle().fill(.red))
            .glassSurface(in: Circle())
            .scaleEffect(pulse ? 1.18 : 0.9)
            .opacity(pulse ? 1 : 0.55)
            .offset(x: 7, y: -7)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
    }
}
