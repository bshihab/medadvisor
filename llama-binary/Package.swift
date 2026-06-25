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
            targets: ["llama-cpp"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "llama-cpp",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b7484/llama-b7484-xcframework.zip",
            checksum: "c384d4f6a8d822884e3f14668a48c6758fe74de77bc51a443b2d5be5a7da505b"
        )
    ]
)
