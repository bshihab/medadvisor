// FoundationModels bench runner — drives Apple's on-device system language
// model from the command line so the Python harness (bench_fm.py) can score it
// with the exact app prompts/parser. macOS only; built with plain swiftc, no
// Xcode (see bench_fm.py, which builds this automatically).
//
// Protocol: JSON Lines over stdin/stdout.
//   in:  {"id": "case:criterion", "prompt": "...", "maxTokens": 180}
//   out: {"id": ..., "ok": true,  "text": "...", "latency": 1.23}
//        {"id": ..., "ok": false, "errorKind": "guardrail"|"contextWindow"|"other",
//         "errorDetail": "...", "latency": 1.23}
// On launch, one handshake line: {"ready": true|false, "availability": "..."}.
//
// Choices that mirror the app / keep results comparable:
// - GREEDY sampling (the app re-applied deterministic greedy scoring in 9b578bf).
// - A FRESH session per request — the app scores its 16 criteria independently.
// - The whole scoring prompt goes in as the user turn (same as bench_realistic.py
//   sends it to mlx); no system instructions, so nothing differs but the model.

import Foundation
import FoundationModels

struct Request: Decodable {
    let id: String
    let prompt: String
    let maxTokens: Int?
    /// Use SystemLanguageModel's permissive content-transformation guardrails
    /// instead of the defaults — for probing whether a refusal is avoidable.
    let permissive: Bool?
}

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

// Optional first argument: path to a trained .fmadapter package. With it, the
// session runs Apple's base model THROUGH our adapter — the only way to learn
// whether a checkpoint that scores well in PyTorch also scores well on the
// real on-device stack (Apple warns the toolkit's training weights "may not
// match the performance of the Foundation Models framework exactly").
let adapterPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

let model: SystemLanguageModel
let permissiveModel: SystemLanguageModel
if let adapterPath {
    do {
        let adapter = try SystemLanguageModel.Adapter(
            fileURL: URL(fileURLWithPath: adapterPath))
        model = SystemLanguageModel(adapter: adapter)
        permissiveModel = SystemLanguageModel(
            adapter: adapter, guardrails: .permissiveContentTransformations)
    } catch {
        emit(["ready": false, "availability": "adapterLoadFailed: \(error)"])
        exit(3)
    }
} else {
    model = SystemLanguageModel.default
    permissiveModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)
}

guard case .available = model.availability else {
    emit(["ready": false, "availability": String(describing: model.availability)])
    exit(2)
}
emit(["ready": true, "availability": "available",
      "adapter": adapterPath ?? "none"])

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let req = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
        emit(["id": "?", "ok": false, "errorKind": "badRequest", "errorDetail": "undecodable line"])
        continue
    }
    let options = GenerationOptions(sampling: .greedy,
                                    maximumResponseTokens: req.maxTokens ?? 180)
    let session = LanguageModelSession(model: (req.permissive ?? false) ? permissiveModel : model)
    let t0 = Date()
    do {
        let response = try await session.respond(to: req.prompt, options: options)
        emit(["id": req.id, "ok": true, "text": response.content,
              "latency": Date().timeIntervalSince(t0)])
    } catch let error as LanguageModelSession.GenerationError {
        let kind: String
        switch error {
        case .guardrailViolation: kind = "guardrail"
        case .exceededContextWindowSize: kind = "contextWindow"
        default: kind = "other"
        }
        emit(["id": req.id, "ok": false, "errorKind": kind,
              "errorDetail": String(describing: error),
              "latency": Date().timeIntervalSince(t0)])
    } catch {
        emit(["id": req.id, "ok": false, "errorKind": "other",
              "errorDetail": String(describing: error),
              "latency": Date().timeIntervalSince(t0)])
    }
}
