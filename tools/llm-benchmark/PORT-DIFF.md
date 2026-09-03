# app_scoring.py ↔ Analysis.swift port fidelity

Re-synced **2026-07-22** against `Sources/Analysis.swift` @ `9b578bf`
(branch `ane-experiment`, off `origin/review-fixes`).

Why: the July-1 bake-off numbers (Qwen 96% / 3.3% / 94%) were measured on the
old port. Commit `3ad3ea0` then changed the shipping Swift. Any new model
benchmarked on the old port would not be comparable to what ships. Re-baseline
results live in `results/` with this date.

## Behaviors ported (Swift → Python)

| Behavior | Analysis.swift | app_scoring.py | Changed in 3ad3ea0? |
|---|---|---|---|
| Scoring prefix text | `scoringPrefix` (L61) | `SCORING_PREFIX` | no — identical |
| Criterion suffix spacing (`\n` between extras and "Answer now") | `criterionSuffix` (L118) | `build_prompt` | whitespace-only fix |
| **Placeholder stripping** ("[Director to specify …]", TBD) from `whatGoodLooksLike`/`requiredElements` | `isPlaceholder` (L109) | `is_placeholder` | **yes — new**. Affects this bench: `accurate_info` + `safety_net` in outpatient-clinic.json each carry one placeholder requiredElement that the old harness fed to the model |
| **Evidence guardrail**: verbatim substring OR contiguous 4-word phrase OR ≥60% of ≥4-char words present (min 2) | `isSupported` (L354) | `_supported` | **yes — was any single shared ≥4-char word**. This is the drift most likely to move the numbers (a hallucinated quote sharing one common word no longer rescues a "met") |
| N/A keyword (`n/a`/`not applicable`/`na`) recognized first; honored only when `allowsNA` | `keyword` (L331), L264 | `_keyword`, `allows_na` | yes — per-criterion N/A |
| `#` stripped with other markdown lead-in | `clean` (L319) | `_clean` regex | yes |
| Last `EVIDENCE:` line wins (not first) | L270-274 loop | label scan loop | parity fix |
| Colon-less `EVIDENCE …` line yields **no** value (falls to between-lines fallback) | `value(after:)` (L340) | `_value_after` | parity fix — old Python swallowed the whole line as the quote |
| Evidence fallback: first plausible line between RESULT and TIP | L275-287 | unchanged | no |
| Speaker-label stripping + quote-char trim + `none`→nil, **after** fallback, before guardrail | L288-291 | unchanged order | no |
| Normalize: lowercase, unicode-alnum-only, collapse | `normalize` (L382) | `_norm` (`str.isalnum`, matching Swift's `isLetter\|\|isNumber`) | parity fix — old Python was ASCII-only |

## Deliberately NOT ported

- **Applicability (N/A) gate** (`applicabilityGateSuffix`, L140): the bench's
  ground-truth labels are all met/missed — no case exercises N/A, and the app
  only gates `naAllowed` criteria. Out of bench scope; revisit if a case with
  N/A labels is ever added.
- **TIP capture**: parsed identically for control flow (TIP terminates the
  evidence fallback) but the tip text isn't returned — the bench doesn't score
  it.
- **Summary prompt / attribution prompt**: separate benches.

## Sampling & generation parity

- App scoring: deterministic **greedy** (re-applied in `9b578bf`),
  `maxTokens: 180` per criterion (EncounterProcessor L198).
- Bench: `mlx_lm.generate` default temp 0.0 = greedy, `max_tokens=180`. Match.

## Verification

```bash
cd tools/llm-benchmark
python -m pytest test_app_scoring.py -q    # parser/guardrail unit tests
```

## Re-sync 2026-09-03 — verify pass shipped (Python → Swift this time)

The direction reversed: `VERIFY_PROMPT` / `verification_rejects` were born in
`app_scoring.py` as a measured candidate change and are now ported INTO
`Analysis.swift` (`PromptBuilder.verifyPrefix`/`verifySuffix`,
`FeedbackParser.verificationRejects`) and wired in `EncounterProcessor` as a
phase after scoring. Parity points:

- Swift `verifyPrefix + verifySuffix` concatenates byte-identical to Python
  `build_verify_prompt` (split so verify calls share one cached transcript
  prefill; the KV cache switches once per consultation, not per criterion).
- Scoping via the rubric's new `aggregate: true` flag (explore_complaint,
  plain_language) — honored by BOTH `EncounterProcessor` and
  `calibration.py verify`. `bench_verify.py` predates the flag and still
  verifies everything (kept as the unscoped measurement tool).
- Fail-open on both sides: generation errors / garbled replies keep the
  grader's verdict.
- Verify token budget: Python 12, Swift 24 (Core AI Qwen3 burns ~5 tokens on
  an empty think block — same reason as the applicability gate's 24).

Evidence for shipping this configuration: calibration/FINDINGS.md (65.1% →
84.1% vs blind human gold; beats the v4 LoRA at 74.6% alone / 79.4% stacked).
