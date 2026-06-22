import SwiftUI

/// M0 spike screen: load an on-device LLM, run a basic prompt, and run the
/// "guardrail probe" — does the model refuse to engage with clinical content?
/// That answer decides whether Gemma 3n is viable as-is.
struct LLMSpikeView: View {
    @StateObject private var llm = LLMSpike()

    private let clinicalProbe = """
    You are evaluating a doctor's communication during a patient consultation. \
    Transcript excerpt:
    "Doctor: I'm afraid the scan shows a mass in your lung that we're worried could be cancer. \
    Patient: Oh god. Doctor: I can see this is a shock. Take all the time you need."
    In 2 sentences: did the doctor deliver this news with empathy? What could improve?
    """

    var body: some View {
        VStack(spacing: 16) {
            Text("On-device LLM spike")
                .font(.headline)

            status

            HStack {
                Button("Test prompt") {
                    Task { await llm.generate(prompt: "Reply with one short friendly sentence.") }
                }
                Button("Clinical probe") {
                    Task { await llm.generate(prompt: clinicalProbe) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)

            ScrollView {
                Text(llm.output.isEmpty ? "Output will appear here." : llm.output)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(llm.output.isEmpty ? .secondary : .primary)
                    .padding()
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding()
    }

    private var isBusy: Bool {
        switch llm.phase {
        case .loading, .generating: return true
        default: return false
        }
    }

    @ViewBuilder private var status: some View {
        switch llm.phase {
        case .idle:
            Text("Tap a button to load the model and generate.")
                .font(.footnote).foregroundStyle(.secondary)
        case .loading(let s):
            ProgressView(s)
        case .ready:
            Text("Model ready (on-device).")
                .font(.footnote).foregroundStyle(.green)
        case .generating:
            ProgressView("Generating on-device…")
        case .error(let e):
            Text(e).font(.footnote).foregroundStyle(.red)
        }
    }
}

#Preview {
    LLMSpikeView()
}
