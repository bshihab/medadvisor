import Foundation
import llama

/// Swift wrapper around llama.cpp's text-generation pipeline (ported from
/// Localabs). Loads a GGUF model (mmap'd, so weights don't count against the
/// iOS app-memory limit), builds a sampler chain, and streams generated tokens.
///
/// `@unchecked Sendable` because llama.cpp pointers aren't Sendable; we serialize
/// access through one detached task per call. Don't call `predict` concurrently.
public final class LlamaContext: @unchecked Sendable {
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let context: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>

    public init(modelPath: String) throws {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99 // offload everything to Metal

        guard let model = llama_load_model_from_file(modelPath.cString(using: .utf8), modelParams) else {
            throw NSError(domain: "LlamaError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load model from \(modelPath)"])
        }

        // llama.cpp b7484 split the vocab off the model — cache it once at init.
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free_model(model)
            throw NSError(domain: "LlamaError", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to extract vocab from model"])
        }

        var ctxParams = llama_context_default_params()
        // Qwen 7B: consultations run up to ~15 min ≈ 3-3.5k tokens of transcript,
        // plus the criterion prompt + output — n_ctx 6144 fits that comfortably
        // (KV cache ~350MB; measured headroom on-device is >3GB since the weights
        // are mmap'd and don't count against the app limit).
        // n_batch 2048 processes the transcript prompt in a couple of passes
        // (n_batch=512 was ~4x slower per criterion).
        ctxParams.n_ctx = 6144
        ctxParams.n_batch = 2048
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 1))
        ctxParams.n_threads_batch = ctxParams.n_threads

        guard let context = llama_new_context_with_model(model, ctxParams) else {
            llama_free_model(model)
            throw NSError(domain: "LlamaError", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create llama context"])
        }

        // Sampler chain: penalties → top-k → top-p → temperature → dist.
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            llama_free(context)
            llama_free_model(model)
            throw NSError(domain: "LlamaError", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create sampler chain"])
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, 1.1, 0.0, 0.0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.3))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        self.model = model
        self.vocab = vocab
        self.context = context
        self.sampler = sampler
    }

    private var currentPredictTask: Task<Void, Never>?

    // Prefix caching: the shared examiner-instructions + transcript prefix is
    // decoded ONCE and its KV state kept; each per-criterion call then rewinds
    // to the end of the prefix and processes only the short question suffix.
    // Re-prefilling the identical transcript 16x dominated scoring time.
    private var cachedPrefix: String?
    private var cachedPrefixTokenCount: Int32 = 0

    /// Streams generated token pieces. Concatenate them for the full response.
    public func predict(prompt: String, maxTokens: Int = 512) -> AsyncStream<String> {
        enqueue { self.runPredict(prompt: prompt, maxTokens: maxTokens, onToken: $0) }
    }

    /// Streams a completion for `prefix + suffix`, reusing the prefix's KV state
    /// across calls when `prefix` is unchanged (identical tokens → identical
    /// output distribution; only the redundant prompt processing is skipped).
    public func predict(prefix: String, suffix: String, maxTokens: Int = 512) -> AsyncStream<String> {
        enqueue { self.runPredictCached(prefix: prefix, suffix: suffix, maxTokens: maxTokens, onToken: $0) }
    }

    private func enqueue(_ body: @escaping (@escaping (String) -> Void) -> Void) -> AsyncStream<String> {
        let prior = currentPredictTask
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                if let prior { _ = await prior.value }
                body { continuation.yield($0) }
                continuation.finish()
            }
            self.currentPredictTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runPredict(prompt: String, maxTokens: Int, onToken: (String) -> Void) {
        // Independent call — clear residual KV (invalidates any cached prefix).
        llama_memory_clear(llama_get_memory(context), true)
        cachedPrefix = nil
        cachedPrefixTokenCount = 0
        llama_sampler_reset(sampler)

        guard decode(text: prompt, addBOS: true) != nil else { return }
        generateLoop(maxTokens: maxTokens, onToken: onToken)
    }

    private func runPredictCached(prefix: String, suffix: String, maxTokens: Int, onToken: (String) -> Void) {
        llama_sampler_reset(sampler)
        let memory = llama_get_memory(context)

        if cachedPrefix == prefix, cachedPrefixTokenCount > 0 {
            // Rewind to the end of the prefix: drop the previous call's suffix
            // + generated tokens, keep the expensive transcript state.
            llama_memory_seq_rm(memory, 0, cachedPrefixTokenCount, -1)
        } else {
            llama_memory_clear(memory, true)
            cachedPrefix = nil
            cachedPrefixTokenCount = 0
            guard let n = decode(text: prefix, addBOS: true) else { return }
            cachedPrefix = prefix
            cachedPrefixTokenCount = n
        }

        guard decode(text: suffix, addBOS: false) != nil else { return }
        generateLoop(maxTokens: maxTokens, onToken: onToken)
    }

    /// Tokenizes and decodes `text`, continuing from the current KV state.
    /// Returns the token count, or nil on failure.
    private func decode(text: String, addBOS: Bool) -> Int32? {
        let cstr = Array(text.utf8CString)
        let nCtx = Int32(llama_n_ctx(context))
        var tokens = [llama_token](repeating: 0, count: Int(nCtx))
        let n = llama_tokenize(
            vocab, cstr, Int32(cstr.count - 1),
            &tokens, nCtx,
            addBOS,
            true   // parse_special — required for chat-template markers
        )
        guard n > 0 else {
            print("[LlamaContext] Tokenize failed (\(n), n_ctx=\(nCtx)) — text likely too long.")
            return nil
        }
        var batch = llama_batch_get_one(&tokens, n)
        guard llama_decode(context, batch) == 0 else { return nil }
        return n
    }

    private func generateLoop(maxTokens: Int, onToken: (String) -> Void) {
        var generated = 0
        while generated < maxTokens {
            if Task.isCancelled { return }

            let nextToken = llama_sampler_sample(sampler, context, -1)
            if llama_token_is_eog(vocab, nextToken) { return }
            llama_sampler_accept(sampler, nextToken)

            var buf = [CChar](repeating: 0, count: 128)
            let nChars = llama_token_to_piece(vocab, nextToken, &buf, Int32(buf.count), 0, true)
            if nChars > 0 {
                buf[Int(nChars)] = 0
                let piece = String(cString: buf)
                if !piece.isEmpty { onToken(piece) }
            }

            var nextTokenVar = nextToken
            var stepBatch = llama_batch_get_one(&nextTokenVar, 1)
            guard llama_decode(context, stepBatch) == 0 else { return }
            generated += 1
        }
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_free_model(model)
        llama_backend_free()
    }
}
