# Calibration findings — 2026-09-03

First human-vs-judge calibration: Bilal's blind gold (64 decisions, 4
LLM-drafted transcripts of varied quality) vs the shipped judge
(Qwen3.5-4B-4bit, no-think, the app's exact prompt/parser). Full diff in
`REPORT.md`; raw verdicts in `judge/`.

## Headline

| Comparison | Binary agreement |
|---|---|
| Bilal vs Claude (two careful raters — the human band) | 54/63 = **85.7%** |
| Claude vs judge | 48/63 = 76.2% |
| **Bilal (gold) vs judge** | 41/63 = **65.1%** |

- **All 22 judge–gold disagreements are over-credits. Zero under-credits.**
- **14 of the 22 (22% of all rows) are consensus errors** — both human raters
  said not-met, including the strictest and the most lenient reading. These
  stand regardless of rater strictness (list in REPORT.md; all in the three
  flawed consultations).
- Bilal credited **40%** of criteria; the judge credited **75%**. On the
  deliberately rushed consultation (gold: 0/16 met) the judge credited
  **8/16** — the "feedback rubber-stamps everything" complaint, reproduced
  under controlled conditions. Agreement was fine only on the good
  consultation (14/16), i.e. the judge cannot see badness, only goodness.

## Why the synthetic 96.1% did not transfer

The corrected 240-decision benchmark constructs a "missed" criterion by
*omitting* the behavior entirely — absence is clean. These transcripts fail
the way real consultations fail: **degraded execution** — a perfunctory
"Anything else?" flung after the prescription, a plan issued without
involvement, warmth-adjacent lines in a cold visit. The judge has no working
concept of partial credit (it emitted zero "partial" verdicts in 64 calls
here, as on all 240 synthetic calls); every degraded behavior rounds up to
"done". 10 of the 22 disagreements are exactly human-partial → judge-met.

The old failure modes from `error_analysis.md` also reappear on realistic
text, now against human gold rather than a disputed key:

- **Patient-speech credited to the clinician** (the explicit prompt rule):
  headache explore_perspective and respond_emotion cite the *patient's* own
  worry monologue; rash avoid_interrupting cites the patient's washing-powder
  line.
- **Wrong-behavior quotes**: the salbutamol prescription line offered as
  evidence for avoid_interrupting *and* support_respect; "sorry, the system's
  running slow today" as evidence of a comfortable tone; "Anything else?"
  double-credited as what_else and invite_questions.

## Caveats

n=63; transcripts are LLM-authored (messier than the benchmark, still tidier
than reality); single human gold rater with a deliberately strict partial
standard — but the 14-row consensus subset is immune to that caveat.

## Verifier results (added 2026-09-03, after the automated `verify` run)

| Config | vs gold |
|---|---|
| Judge single pass | 41/63 = 65.1% |
| + verifier (all criteria) | 49/63 = 77.8% (14 over-credits fixed, 6 correct credits destroyed) |
| + verifier scoped: skip explore_complaint & plain_language | **53/63 = 84.1%** |
| Human inter-rater band (Bilal vs Claude) | 54/63 = 85.7% |

The verifier's damage is concentrated and mechanistically explainable: it
wrongly rejects **aggregate criteria** — thorough complaint exploration,
consistently plain language — whose proof is spread across the whole visit,
so no single quote can demonstrate them and the sceptic rejects good credits
(explore_complaint 1 fixed / 3 destroyed; plain_language 0/2). On every other
criterion it ran near-pure profit (13 fixed, 1 destroyed). Skipping those two
puts the judge **statistically inside the human-disagreement band**: of its
10 remaining disagreements with Bilal, only ~3 are consensus errors (both
human raters agreed the judge was wrong — all on the rushed cough visit);
the rest are rows where the two human raters also split.

Cross-checks and caveats:

- On the corrected synthetic 240 set the verifier is net-negative (96.1% →
  93.0%, scoped or not — scoping is a no-op there since synthetic evidence is
  always one clean snippet). The two datasets disagree because they test
  different regimes: clean omissions (synthetic) vs degraded execution
  (realistic). Production consultations resemble the second. Notably the
  synthetic damage lands on support_respect and avoid_interrupting — the same
  criteria that were the verifier's biggest *wins* on realistic data: the
  verifier's per-criterion value depends on how often credits are bogus.
- The skip-list was chosen on these same 63 rows (overfit risk, n small). The
  mechanism is principled, but validate on fresh human transcripts before
  trusting the exact number.

**Recommended ship config: judge + scoped verify pass** (skip the aggregate
criteria — ideally a per-criterion rubric flag, e.g. `aggregate: true` on
explore_complaint and plain_language, rather than hardcoded ids). Cost ~1.7x
calls here (only 'done' verdicts are re-checked). The fine-tune stays shelved:
after scoping, the consensus error count is ~3 rows out of 63.

## v4 fine-tune result (2026-09-03, Modal run — see results/V4-CLOUD-REPORT.txt)

The v4 adapter (Bilal-standard data, v3's winning recipe, lr5e-5 step 120)
against the pre-registered bars, single pass on calibration gold:

| Config | vs gold |
|---|---|
| Stock (MLX and bf16 cloud — identical) | 65.1% |
| **v4 adapter, single pass** | **74.6%** |
| Stock + scoped verifier (the free alternative) | 84.1% |
| Human band | 85.7% |

**Decision, per the bar set before training: the adapter does not ship; the
scoped verifier does.** The fine-tune genuinely worked — +9.5 on gold, +7.9
on the in-stack 240 with over-score halved, 95.8/3.3/94.4 on the 48-case
screen — but it lands ~10 points short of what the second-pass verifier
already provides for free.

Failure anatomy (16 disagreements, was 22 for stock): over-credits fell 22 →
11, but **5 under-credits appeared** (stock had zero) — the trained
strictness now denies real credit, almost entirely on the aggregate criteria
(plain_language ×2, explore_complaint, open_questions, set_tone), the same
criteria the verifier damages. Third independent confirmation of the
mechanism: quote-demanding scepticism cannot judge whole-visit criteria. The
stubborn over-credits are also the familiar ones (the flung "Anything
else?", "Shirt up" as exam explanation, the patient's worry monologue still
credited as explore_perspective despite trap training). Under-credit TIPs
parrot training phrases verbatim — the adapter fit the style hard.

Stacking tested (2026-09-03, modal_verify_stack.py, same cloud stack):
tuned + scoped verifier = **79.4%** (3 over-credits fixed, 0 destroyed) vs
stock + scoped verifier = **81.0%** in-stack (84.1% in the MLX stack — two
rows of stack noise on n=63; both stacks agree on the ranking). As predicted,
the verifier cannot restore the adapter's 5 under-credits, so the stack
starts handicapped and never catches up. **The fine-tune adds nothing on top
of the trick.** Final ship config: stock judge + scoped verifier — ported
into Analysis.swift/EncounterProcessor the same day (see PORT-DIFF.md).
The adapter stays a research artifact (Modal volume medadvisor-qwen-v4-out,
lr5e-5/step120). Remaining validation: human role-played transcripts.

## Implications (in order of cost)

1. **The over-crediting problem is real, current, and large on realistic
   input.** The post-audit synthetic number (96.1%, 10.5% over-score) is a
   ceiling from clean absences, not a forecast for production.
2. **Re-test the second-pass verifier on this data.** On the corrected
   synthetic set it was net-negative (fixing label noise, breaking recall),
   but this operating point is different: 22/63 over-credits leaves it far
   more to fix and (with recall here at 100%) less to break. Cheap: one more
   Air run.
3. **Prompt iteration targeting degraded execution**: force the partial/done
   boundary ("done requires the behavior performed fully and sincerely; a
   token gesture is partial at best"), and re-emphasize patient-speech
   rejection. Measure on this same gold.
4. **If 2–3 fail, a fine-tune is now genuinely justified** — with a real
   target slice for the first time: partial-quality behaviors, patient-speech
   rejection, wrong-behavior quote discrimination. Validate against these
   sheets (held out, never trained on) plus fresh human transcripts.
5. **Get 2–3 genuinely human role-played transcripts** before betting weights
   on any of this.

## Restore-pass idea (evaluated on paper 2026-09-03, not run)

Could a symmetric second pass re-open "missed" verdicts and award credit?
Measured incidence in the ship config (stock + scoped verifier) on the gold:
**1 wrongly-denied credit vs 27 correctly-denied** — a restore pass needs
>96% precision to break even, executed by a model whose known bias is
inventing credit. Expected value negative; not run. Revisit only if human-
transcript validation shows the shipped config denying real credit at a
meaningful rate.

## Apple Foundation Models + verifier (2026-09-03, calibration_fm.py, macOS 26.3.1)

Could the download-free system model wear the verifier and compete? Measured
on the same gold (1 guardrail refusal excluded, never laundered):

| Config | vs gold |
|---|---|
| Apple FM, single pass | 30/62 = **48.4%** |
| Apple FM + scoped verifier | 44/62 = **71.0%** (17 over-credits fixed, 3 destroyed) |
| Shipped config (Qwen stock + scoped verifier) | 81–84% |

The verifier's biggest lift yet (+22.6 — its value scales with how bogus the
credits are; FM rubber-stamps the most) and still 13 points short of the
shipped config: the trick cannot rescue a 48% base. FM also refused a medical
grading prompt outright once in 64 decisions — a production liability on its
own. The download-free dream is not close today, and the adapter treadmill
(version-locked, non-redistributable) remains the only Apple route to a
better base. **Cheap standing check: rerun `python calibration_fm.py` +
`calibration.py report --tag fm` after each OS update — if Apple's base model
ever closes the gap, this one-command harness will say so.**
