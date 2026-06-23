import SwiftUI

/// Full-screen success animation shown when analysis completes —
/// a circle + drawn checkmark (Apple-Pay style), then "Analysis complete".
struct CheckmarkOverlay: View {
    @State private var drawn = false
    @State private var circled = false

    var body: some View {
        ZStack {
            Color(.systemBackground).opacity(0.92).ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .trim(from: 0, to: circled ? 1 : 0)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 130, height: 130)
                        .rotationEffect(.degrees(-90))

                    Checkmark()
                        .trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                        .frame(width: 64, height: 52)
                }

                Text("Analysis complete")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45)) { circled = true }
            withAnimation(.easeInOut(duration: 0.45).delay(0.35)) { drawn = true }
        }
    }
}

/// A check mark path drawn left→corner→up-right.
private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
