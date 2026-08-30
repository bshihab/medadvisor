# Apple on-device foundation model — phases 2–3 results

**Measured 2026-07-22 → 2026-07-25 · branch `ane-experiment` (worktree, shipping
path untouched) · Mac mini M4 / 16 GB / macOS 26.3.1 · adapter trained on Modal
A10G · scoring always via `app_scoring.py`, the port of `Analysis.swift` @ `9b578bf`**

## FINAL: measured on the real iPhone, iOS 27 (2026-07-26)

Ran the 48 prompts through the **stock iOS 27 system model** on an iPhone
(`tools/ios-fm-probe`, scored here by `score_ios_probe.py`). This was the last
open question, and it needed no toolkit, entitlement, or adapter.

| Model | Accuracy | Over-score ↓ | Recall ↑ | Refusals |
|---|---|---|---|---|
| **Qwen2.5-7B Q4 — ships today** | **87.5%** | **13.3%** | 88.9% | 0 |
| Apple FM stock — macOS 26.3 (old model) | 54.3% | 75.0% | 100% | 2 |
| **Apple FM stock — iOS 27, on device** | **70.8%** | **46.7%** | 100% | **0** |
| Apple FM + our adapter — macOS 26.3 | 93.8% | 6.7% | 94.4% | 0 |

**The efficiency prize is real and now proven on device:**
48 criterion calls (≈3 full analyses) in 126 s at 13.1 tok/s, **0% battery drop,
thermal never left `nominal`.** Compare the shipping llama.cpp/Metal path: ~5%
battery *per analysis* and "serious" thermal. That was the entire motivation for
this experiment and it holds up completely.

**The accuracy still fails.** iOS 27's rebuilt model is genuinely better than
macOS 26.3's (54.3% → 70.8%, over-score 75% → 46.7%), so Apple's "better across
the board" is directionally true — but it still wrongly credits **nearly half of
all absent behaviors**, versus Qwen's 13.3%. Every one of its 14 errors is an
over-score; there are zero under-scores. The signature failure is quoting
*anything* rather than reading for the specific behavior — "Come back if it's not
gone in a month" was credited for safety-netting AND shared plan AND inviting
questions; "I'll start you on an antidepressant, take one a day" was credited for
responding to emotion, support/respect, plain language, accurate info AND shared
plan. Five criteria, one unilateral instruction.

**Two corrections to earlier claims in this document:**
1. **Context is 4096 on iOS 27, not 8192.** `SystemLanguageModel.contextSize`
   reports **4096** on the device. Apple's WWDC26 session showed 8192, and I
   speculated that would erase the context caveat — it does not. The knife-edge
   constraint stands: a 3.5k-token transcript + ~700-token prefix barely fits,
   with no headroom, against llama.cpp's 6144–8192.
2. **Refusals are gone on iOS 27.** 0/48 at default guardrails, including the
   depression consult that produced 2 hard refusals on macOS 26.3. The
   `.permissiveContentTransformations` dependency is not needed on 27.

**Conclusion:** the Apple on-device model is essentially free in battery and
thermal terms and still not accurate enough to grade this rubric. The one thing
that closes the accuracy gap — a task-trained adapter — is exactly the thing
Apple has no toolkit for on iOS 27. **Keep shipping Qwen2.5-7B.**

## Headline (adapter experiment, macOS 26.3)

A LoRA adapter trained on ~600 synthetic strict-grading examples takes Apple's
~3B on-device system model from **unusable (54% accuracy, rubber-stamps 75% of
absent behaviors) to at-or-above the shipped Qwen2.5-7B** on this benchmark —
verified on the real FoundationModels runtime, not just in PyTorch.

| Model | Accuracy | Over-score ↓ | Recall(met) ↑ | Refusals |
|---|---|---|---|---|
| **Qwen2.5-7B Q4 — ships today** (re-baselined 07-22) | 87.5% (42/48) | 13.3% (4/30) | 88.9% (16/18) | 0 |
| Apple FM stock | 54.3% (25/46) | 75.0% (21/28) | 100% (18/18) | **2 hard** |
| + adapter · dose 48, strictness-biased, lr 1e-3 | 62.5% | 0% | 0% | 0 |
| + adapter · dose 48, balanced, lr 3e-4 | 68.8% | 0% | 16.7% | 0 |
| + adapter · **full 569**, lr 1e-3 (Apple default) | 79.2% | 3.3% | 50.0% | 0 |
| + adapter · **full 569, lr 3e-4** (PyTorch/GPU) | **93.8%** (45/48) | **6.7%** (2/30) | **94.4%** (17/18) | 0 |
| + adapter · **full 569, lr 3e-4** — **real FoundationModels runtime** | **93.8%** (45/48) | **6.7%** (2/30) | **94.4%** (17/18) | **0** |

The last two rows are **identical, error for error** — the same three decisions
wrong (`rushed_cough/explore_complaint`, `rushed_cough/plain_language`,
`poor_lowmood/respond_emotion`). Apple warns the toolkit's training weights "may
not match the Foundation Models framework exactly"; here they matched exactly.

## What the numbers say

- **Leniency is trainable.** Over-scoring — the product's cardinal sin and the
  original complaint that triggered the whole bake-off — fell **75% → 6.7%**,
  while recall *rose* to 94.4%. Both directions improved at once, which is what
  the July-1 bake-off concluded small models could not do.
- **Learning rate was the whole story.** Apple's documented default (1e-3) still
  overcorrects (50% recall); a third of it lands in the middle. The dose-test
  collapses (0% and 16.7% recall) were an artifact of 6 full-rate updates with
  no warmup, not evidence of a hard 3B ceiling.
- **The 3 residual errors are balanced** — one under-credit, two over-credits.
  A biased grader fails in one direction; this one doesn't.
- **The refusal problem disappeared.** Stock FM hard-refused 2 calls on the
  depression consult under default guardrails. With the adapter, those same two
  calls return normal verdicts, and the full 48 ran with **zero refusals on
  default guardrails** — so `.permissiveContentTransformations` is *no longer
  load-bearing*, removing the phase-2 product caveat.
- **Adapter/OS compatibility held**: toolkit 26.0.0's adapter loaded on
  macOS 26.3.1's system model with no version mismatch.

## Side effect worth more than the experiment: few-shot helps the SHIPPING model

The same worked-examples block that wrecked the 3B **improves Qwen2.5-7B**, and
this was measured on the 240-decision snippet set (5x the resolution of the
realistic set, same noise in both arms so the comparison holds):

| Qwen2.5-7B, 240 decisions | Accuracy | Over-score ↓ | Recall(met) ↑ |
|---|---|---|---|
| baseline | 79.2% (190/240) | 36.6% (41/112) | 93.0% (119/128) |
| **+ few-shot block** | **83.8% (201/240)** | **24.1% (27/112)** | 90.6% (116/128) |

**14 over-scores fixed for 3 recall losses — net +11 correct decisions.** On the
realistic 48-case set the same change was +1 decision (87.5% → 89.6%, over-score
13.3% → 10.0%), i.e. directionally identical but underpowered. Capability
matters: the 7B exploits worked examples, the 3B is confused by them.

Cost: ~170 tokens, and they sit inside the KV-cached shared prefix, so the
prefill is paid **once per analysis, not 16x**. No new assets, no download, works
on every OS version, and it applies to the model that ships today.

Status: **candidate change, not yet recommended for ship.** It is gated behind
`APP_SCORING_FEW_SHOT=1` in `app_scoring.py` and has NOT been ported to
`Analysis.swift`. Validate against the director's gold scores first — the
snippet set measures capability, not correctness. Reproduce:

```bash
python bench_scoring.py --model mlx-community/Qwen2.5-7B-Instruct-4bit
APP_SCORING_FEW_SHOT=1 python bench_scoring.py --model mlx-community/Qwen2.5-7B-Instruct-4bit
```

## Two app bugs this experiment surfaced (both affect the shipping Qwen path)

1. **The N/A gate is structurally broken.** `EncounterProcessor:173` builds it as
   *cached scoring prefix + gate suffix*, but the prefix ends with "Answer in
   EXACTLY three lines: RESULT/EVIDENCE/TIP". That instruction wins: Apple FM
   answered the gate with `RESULT: done / EVIDENCE: "I'd like to examine you
   now…"` (stock AND adapter). The parser then substring-matches for
   "no"/"did not"/"didn't", so either (a) nothing matches → the gate silently
   no-ops and a genuinely inapplicable criterion is graded "missed" instead of
   N/A (the bug `3ad3ea0` set out to fix), or (b) an evidence quote containing
   "didn't" flips it to N/A → the criterion leaves the denominator and the score
   is silently inflated. Live for `explain_exam` (outpatient) and
   `include_family` (inpatient). Fix: don't inherit the three-line prefix for
   the gate call, or parse strictly (exact "yes"/"no" token only).
2. **The summary prompt cannot be specific.** `summaryPrompt` passes only the
   *count* ("met 11 of 16"), never which criteria were missed — so every model
   returns circular advice ("focus on meeting the remaining 5 criteria").
   Measured on both stock FM and the adapter; Qwen has the same input. Fix: pass
   the missed criterion names.

Neither is Apple-specific. Both are cheap wins on the shipping path.

## The adapter degrades the PROSE, which the benchmark never scored

Measured 2026-07-25 by extracting the TIP line from every saved generation:

| | tips emitted | **distinct** tips | character |
|---|---|---|---|
| Stock FM | 39 | **39** | specific, varied, per-criterion advice |
| + adapter | 29 | **5** | mostly one canned training string |

Stock produces e.g. *"Ensure questions are open-ended by avoiding yes/no
questions and prompting detailed responses."* The adapter mostly emits
*"This was not attempted at all in the consultation."* — verbatim from
`gen_adapter_dataset.py`, which used that single string for every plain-absence
example (~30% of the 569). The model learned to parrot it.

**This is Goodhart's law and it matters more than the accuracy win.** The
benchmark scores the met/missed verdict; the *product* is the coaching text a
trainee reads. Verdict accuracy went 54.3% → 93.8% while the feedback prose
collapsed to five stock phrases. **As trained, this adapter is not shippable
even if it could load.**

Fixes, in order of cleanliness:
1. **Mask the TIP/EVIDENCE lines out of the training loss** so only the verdict
   token is learned — the verdict was the only thing that needed fixing.
2. Generate varied, criterion-specific tips in the dataset (the generic
   absence string must not be reused across examples).
3. Two-pass: adapter decides the verdict, the stock model writes the prose.

Also still **untested with the Apple model**: the 2-sentence prose summary
(`summaryPrompt`) and speaker attribution — the app's other two LLM jobs. The
benchmark has never scored prose for any model (the README says so); that gap is
now known to be load-bearing.

## Caveats — read these before quoting the headline

1. **Phrase-level contamination (measured, disclosed).** The training data was
   authored in the same session that read `realistic_cases.json`, and some
   phrasing leaked. Worst case Jaccard 0.64: bench "Before we finish, what
   questions do you have for me?" vs training "Before we finish — what questions
   do you have for me? Nothing is too small to ask." Zero exact duplicates;
   median line similarity 0.24; but 2–3 high-similarity lines map to specific
   criteria. Discounting them lands ≈89.6%. **Defensible claim: "matches Qwen
   within this test's resolution", NOT "beats Qwen."** Mitigating context: these
   are the canonical phrases the curriculum teaches, so some convergence is
   unavoidable and arguably in-distribution.
2. **48 decisions, 3 transcripts.** 45/48 vs 42/48 is a 3-decision gap — not
   significant. The README's own caveat applies: this set ranks models, it does
   not measure them. **The director's gold scores remain the real validation.**
3. **Context ceiling unchanged:** ~4096 tokens. A 3.5k-token transcript + the
   ~700-token prefix fits with almost no headroom (llama.cpp runs 6144–8192).
   Overflow throws a typed, catchable error — never silent truncation.
4. **Not measured on-device.** All of this is Mac-side. iPhone tokens/sec,
   thermals, and battery are unmeasured, and the phone's base model revision may
   differ from macOS 26.3's.

## The blocker that outranks all of it

**Toolkit 26.0.0 is the last release and is explicitly incompatible with iOS 27+
— and the test iPhone runs iOS 27.** No successor toolkit exists (the only
"Core AI" download in Apple's catalog is a *debugger*). So:

- This adapter **cannot be loaded on the target device today**, at any accuracy.
- Any future OS that revs the base model orphans the adapter until retrained,
  and right now there is no tool to retrain with.
- Shipping would also need the Foundation Models Adapter Entitlement (requested
  by the Account Holder), server-hosted adapter delivery via Background Assets,
  and ~160 MB per adapter version — so even success is "160 MB download", not
  "zero download."

**Verdict: the science question is answered YES; the shipping path is closed by
Apple's own versioning.** Recommendation: keep shipping Qwen2.5-7B, bank this
result, and re-run the (now fully automated) pipeline if Apple ships an OS-27-era
adapter mechanism. The experiment cost $0.76 of GPU time and never touched the
shipping path.

## Revival checklist — what to do when, and what NOT to bother with

**Do not plan to train on a Mac.** Apple asks for 32 GB; the 16 GB mini only
worked via the bf16 conversion + loader patch and was still ~15 h (swap-bound).
The cloud pipeline in `tools/cloud-train/` does the same run in ~20 min for
~$0.76 and is already wired end to end. A MacBook Air is worse than the mini and
is needed for Xcode.

**A new OS release is NOT a new toolkit.** The OS ships the *runtime* (run the
model, load a matching adapter). The toolkit is a separate download containing
the base *weights* you train against. Only the latter unblocks training.

### Trigger 1 — a new OS ships (macOS 26.4+/27, iOS 27)
Costs 20 min, needs no toolkit, and may make everything below moot:
1. `python bench_fm.py` — stock accuracy on the new model. Apple calls the OS-27
   model "rebuilt from the ground up, better across the board", and our 54.3%
   stock number is against macOS 26.3's *older* model. **If stock clears the bar,
   no adapter is needed and the whole version-pinning problem disappears.**
2. Replace the empirical context probe with the real API (added in 26.4):
   `SystemLanguageModel().contextSize` — reported as 8192 in Apple's WWDC26
   session vs the ~4096 measured here. 8192 would erase the context caveat.
3. `python bench_fm.py --adapter …/strict_grader.fmadapter` — does the OS-26
   adapter still load after a base-model update? This measures the retraining
   tax directly. Expect failure on 27 (Apple says so); a 26.x point release is
   the interesting test.

### Trigger 2 — Apple ships an adapter toolkit for the current OS
Watch the version table on
<https://developer.apple.com/apple-intelligence/foundation-models-adapter> for a
new row, or a Core AI-branded *trainer* in the downloads catalog (as of
2026-07-25 the only Core AI download is a **Debugger**, and the WWDC26
Foundation Models session mentions adapter training nowhere). Then:
1. Download it; put its `assets/` in place of the 26.0.0 ones.
2. `python gen_adapter_dataset.py` (data is version-independent).
3. `cd tools/cloud-train && ./run_cloud.sh` — trains both LRs and scores.
   **Use lr 3e-4, not Apple's 1e-3 default** — that was the whole difference
   between 79.2% and 93.8%.
4. Export, then `bench_fm.py --adapter …` on the real runtime.
Budget is capped in `modal_train.py` (`BUDGET_USD`).

### Do not repeat
- **Few-shot prompting on the small (3B) model**: measured, made it *worse*
  (54.3% → 40.4%, over-score 75% → 93.3%). See below — the same block HELPS the
  7B, so this is capability-dependent, not a bad idea per se. And beware:
  iterating prompt variants against the same 48 decisions is fitting the test
  set; use the 240-decision snippet set for prompt A/Bs.
- **Exported-model Core AI path**: killed by memory accounting in the earlier
  spike (see `Sources/CoreAIEngine.swift`); unrelated to the system-model path.
- **VM/Docker for testing**: no macOS containers exist, and macOS VMs get no
  Neural Engine passthrough, so FoundationModels won't run.

## Reproduce

```bash
cd tools/llm-benchmark && source .venv/bin/activate
python -m pytest test_app_scoring.py -q          # 18 tests: port fidelity
python bench_realistic.py --model mlx-community/Qwen2.5-7B-Instruct-4bit
python bench_fm.py --probe-context               # context ceiling
python bench_fm.py                               # stock FM
python gen_adapter_dataset.py                    # 569/70 synthetic examples

cd ../cloud-train && ./run_cloud.sh              # GPU train both LRs + score
                                                 # (~20 min, ~$0.40, $7 hard cap)

cd ../adapter-training/adapter_training_toolkit_v26_0_0
.venv/bin/python -m export.export_fmadapter --adapter-name strict_grader \
  --checkpoint checkpoints_cloud_lr3e-4.pt --output-dir ./exports/

cd ../../llm-benchmark                           # the number that counts:
python bench_fm.py --adapter ../adapter-training/adapter_training_toolkit_v26_0_0/exports/strict_grader.fmadapter
```

Artifacts: `results/realistic_*.json` (per-decision rows for every model above),
`data/adapter/{train,valid}.jsonl` (synthetic training data), `PORT-DIFF.md`
(harness fidelity), `exports/strict_grader.fmadapter` (127 MB, gitignored).

## Privacy

Every training example is authored fiction — no patient content, no app
transcripts, nothing derived from real recordings. What left the Mac for the GPU
was Apple's toolkit weights plus that synthetic text. The shipping path
(llama.cpp / Qwen / `LlamaEngine`) was never modified.

---

# 2026-08-30 — the last lever: two-pass verification on Apple's model

The remaining idea worth testing. Apple's iOS 27 model had the ideal shape for
it: **70.8% accuracy, 46.7% over-score, 100% recall** on the 48-case set — 14 of
30 absent behaviours wrongly credited, and nothing correct to lose. Verification
only removes false credits, so there was a lot to remove and no downside risk.

The same technique on Qwen 3.5-4B cut over-scoring **31.2% → 11.6%** at 67%
rejection precision. If it worked here, the Apple path was live again: no 3 GB
download, Neural Engine instead of GPU. Ran it on device via `tools/ios-fm-probe`
(240 prompts, iPhone 17, iOS 27.0) — every "done" verdict challenged with a
second call using the VERIFY_PROMPT wording already measured on Qwen.

## Result: every single verification returned CONFIRM

Zero rejections across the whole run. Accuracy unchanged, because nothing was
removed. What it confirmed:

| Criterion | Evidence the verifier CONFIRMED |
|---|---|
| `safety_net` | "You've done exactly the right thing coming in, and we'll work through this together." |
| `check_understanding` | "What would you prefer?" |
| `explain_exam` | "Please, go on and take your time — I'm listening." |
| `accurate_info` | "You've done exactly the right thing coming in…" |

The prompt explicitly warns that a generic pleasantry does not demonstrate a
specific behaviour, and that a quote showing a DIFFERENT behaviour does not
count. It was shown a line about working through things together, asked whether
that demonstrates safety-netting, and said CONFIRM.

Cost: **1005 s vs 577 s** for the single-pass run — 74% slower for zero gain,
still nominal → fair → serious.

## Why this closes the path rather than just failing

Being inaccurate is fixable from outside; a model that **cannot challenge its own
judgment** is not, because the second pass is the same agreeable model. On Qwen
the identical prompt rejected with 67% precision. Here it rejected nothing.

That was the last available lever. Not weights, not prompting, not guided
generation, not Dynamic Profiles (a behaviour mechanism — it switches
instructions and tools, which cannot fix judgment). Verification had the
strongest prior evidence of any technique, applied to the model with the most
room to gain, and moved nothing.

## Revival trigger — unchanged, and cheap to re-check

A future iOS shipping a genuinely better model. The trajectory is real:
macOS 26.3 was 54.3% / 75.0% over-score; iOS 27 is 70.8% / 46.7% with refusals
down to zero. Re-running the 48-case harness is ~20 minutes:

```
# rebuild tools/ios-fm-probe, run on device, then:
python score_ios_probe.py ~/Downloads/fm_probe_ios.json
```

The prize has not changed: no 3 GB download, and the Neural Engine instead of
the GPU — far less heat and battery than the current ~2 min GPU analysis.

## What ships instead

Qwen 3.5-4B. Across three real recordings read aloud on the target phone:
**44/48 criteria correct vs the 7B's 38/48**, speaker attribution **98.3% vs
85.0%**, and 3.0 GB instead of 4.3 GB.
