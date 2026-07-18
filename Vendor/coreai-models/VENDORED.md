# Vendored: apple/coreai-models

- Upstream: https://github.com/apple/coreai-models
- Vendored at upstream commit: `04a3fd6` (2026-07-17)
- Copied subset: `Package.swift`, `LICENSE`, `swift/` (the SPM package). The
  `python/`, `models/`, and `skills/` trees are export-time tooling that the
  app never builds — run those from a full upstream checkout on the Mac.
- Why vendored instead of the GitHub URL: (1) pins the dependency — upstream
  has no tagged release, so `branch: main` made every build a moving target;
  (2) carries local patches the benchmark needs (below).

## Local patches (marked `MEDADVISOR PATCH` in source)

1. `CoreAILanguageModel.swift` — `respondVanilla`/`respondConstrained` reported
   `cachedTokenCount: 0` unconditionally, so `Usage.Input.cachedTokenCount`
   (the benchmark's prefix-cache metric) always read 0. Now reports the
   engine's `lastPrefixHitCount`.
2. `Package.swift` — added a `CoreAIShared` library product so the app can
   import `CLILogger` and turn on the engine's load-progress logging (upstream
   keeps that target internal, and the default log level is silent).
3. `CoreAIStaticShapeEngine.swift`, `CoreAISequentialEngine.swift`,
   `CoreAIPipelinedEngine.swift` — all three engines full-reset the KV cache
   when a request diverges from history (upstream comment: "partial rewind
   corrupts buffer rotation"), but still set `lastPrefixHitCount` to the
   matched-prefix length. That reports a cache hit whose contents were just
   discarded. Patched to report 0 on the divergence path, the real hit count
   otherwise. Consequence worth knowing: our 16-criteria fan-out (same prefix,
   different suffix per criterion) IS the divergence case — expect
   cachedInputTokens ≈ 0 on every criterion until upstream implements true
   prefix reuse. cachedInputTokens ≈ transcript length would only appear for
   monotonic-extension workloads (one growing conversation).

To diff against upstream: clone upstream at `04a3fd6` and
`diff -r <upstream>/swift Vendor/coreai-models/swift`.
