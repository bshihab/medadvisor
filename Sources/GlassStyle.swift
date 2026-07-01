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
}
