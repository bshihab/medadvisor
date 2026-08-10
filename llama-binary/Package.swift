// swift-tools-version: 6.0
//
// Local SwiftPM wrapper that exposes the llama.cpp xcframework directly as the
// C module `llama`. SPM downloads the prebuilt binary from the release URL
// below (pinned by checksum) — nothing large is committed to this repo.
//
// Ported from the Localabs app, where MedGemma 4B runs on-device via llama.cpp
// with no increased-memory entitlement (llama.cpp mmaps the weights, so they
// don't count against the iOS app-memory limit the way MLX's do).
import PackageDescription

let package = Package(
    name: "llama-binary",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "llama",
            targets: ["llama-cpp-b10243"]
        )
    ],
    targets: [
        // b7484 (2025-12-19) could not load Qwen3.5: llama.cpp only learned the
        // `qwen35` architecture on 2026-02-10 (PR #19468), with follow-up fixes
        // through 2026-03-05. On device that surfaced as "failed to load model"
        // AFTER a successful download and SHA-256 check — the file was fine, the
        // engine had simply never heard of the format.
        //
        // b10243 is also the build the Modal benchmarks ran on (llama.cpp master,
        // 2026-08-03), so the measured 4B numbers describe this engine and not a
        // different one.
        //
        // Verified before bumping: every llama_* symbol LlamaContext.swift calls
        // still exists here. llama_load_model_from_file, llama_free_model and
        // llama_new_context_with_model are deprecated upstream but not removed,
        // so no app code changes — this is a one-line version bump.
        //
        // NOTE: this engine also runs the shipping Qwen2.5-7B. Backward
        // compatibility for old architectures is never dropped, so it loads the
        // same file; what needs checking on device is whether eight months of
        // upstream change shifted its OUTPUT or SPEED. Test the 7B first.
        .binaryTarget(
            // Target renamed from "llama-cpp" on the b7484 -> b10243 bump.
            // SPM names its extracted artifact directory after the TARGET, and it
            // kept handing Xcode the cached b7484 xcframework no matter how many
            // times DerivedData and ~/Library/Caches/org.swift.swiftpm were wiped
            // (confirmed on device: the extracted framework's files stayed dated
            // 2025-12-19, while b10243's zip contains files dated 2026-08-03).
            // A new target name means a new artifact path with no cache to hit.
            name: "llama-cpp-b10243",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10243/llama-b10243-xcframework.zip",
            checksum: "65fc78dd8cffd71488a28ca278edae876333e4fef3aeea5c0257faf3bd4f3abe"
        )
    ]
)
