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
