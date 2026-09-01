# Error analysis — Qwen 3.5-4B (no-think) on the 240-decision gold set

Analysis date: 2026-09-01. Read-only analysis: no harness, gold label, or saved
prediction was modified. Written to inform the fine-tune / no-fine-tune decision.

## What this is based on (provenance)

| Artifact | File | Notes |
|---|---|---|
| Harness | `bench_scoring.py` + `app_scoring.py` | app's exact prompt/parser/guardrail (port of `Analysis.swift`, re-synced 2026-07-22) |
| Gold set | `data/scoring.json` (2026-07-03) | 15 synthetic cases × 16 criteria = 240 decisions |
| Decisions | `results/scoring_mlx-community__Qwen3.5-4B-4bit__nothink.json` | 240 rows: case, criterion, truth, pred |
| Rationale | `results/verify_mlx-community__Qwen3.5-4B-4bit__nothink.json` | pass-1 evidence quote per decision (first 120 chars) |
| Summary | `results/QWEN35-240-REPORT.txt` (run 2026-07-27) | 85.4% acc, 31.2% over-score, 100% recall |

Consistency checks performed:

- The report's numbers reproduce exactly from the saved rows: 205/240 correct,
  **35 misses** (the README's "~85%" ≈ 36 is actually 35), 35/112 over-scores,
  128/128 recall.
- `data/scoring.json` predates the run and its 240 (case, criterion, label)
  triples match the saved rows exactly.
- `bench_scoring.py` doesn't save the model's raw text, but `bench_verify.py`
  (run 2026-07-28, same set, same prompt, greedy decode) saved the parsed
  EVIDENCE quote per decision — and its pass-1 verdict agrees with the scoring
  run on **all 240 rows**, so those quotes are the saved rationale for these
  same deterministic decisions, not a reconstruction. The full RESULT/TIP text
  for the 240 run was never saved (only `bench_realistic.py` saves `raw`, and
  only for the 48-case set); the evidence quote is the substantive part.
- Synthetic-data check: transcripts are assembled programmatically by
  `generate_scoring_dataset.py` (seed 7) from authored snippets in
  `criterion_snippets.json` — one fixed patient opener plus, per criterion,
  either that criterion's Doctor snippet (met) or nothing (missed). No real
  patient data. The tracking commit (9817863) records the same privacy check.

Two structural facts that shape everything below:

1. **All 35 misses are over-scores** (truth missed, model said met). Recall was
   100%, so there are zero under-scores — failure mode (a) "evidence missed"
   cannot occur, and direction is `over` on every row.
2. **Every miss survived the evidence guardrail**, so every miss carries a
   genuine transcript quote — and in all 35 cases that quote is a *different
   criterion's* snippet. The model never fabricated evidence and never emitted
   a format failure (no (d) rows; it also never used "partial" on this run:
   163 met / 77 missed).

## Miss table (all 35)

Direction is **over-score** for every row (see above), so the column is omitted.
"Quoted from" = which snippet the model's evidence quote actually belongs to.
Tercile is by transcript word count (short 142–205 w, med 213–261 w, long
261–333 w; the two 261-word cases split across the med/long boundary by tie).
"Vrf" = what the second-pass verifier later did with this verdict (✓ = confirmed,
✗ = rejected).

Failure-mode tags:
(b) evidence found but judged wrong · (c) rubric/instruction misread ·
(e) questionable gold label. `?` marks an uncertain tag (alternatives given).

| # | Case | Terc | Criterion | Gold→Model | Model's evidence (quoted from) | Tag | Vrf |
|---|---|---|---|---|---|---|---|
| 1 | case001 | med | accurate_info | missed→met | "In simple terms, it's the muscles around your head tightening up — nothing dangerous." + "There are a couple of option…" (plain_language + shared_plan) | (e) | ✓ |
| 2 | case007 | med | accurate_info | missed→met | same composite quote (plain_language + shared_plan) | (e) | ✓ |
| 3 | case000 | long | avoid_interrupting | missed→met | "When exactly did it start, how severe does it get…" (explore_complaint) | (e)? b/e | ✗ |
| 4 | case001 | med | avoid_interrupting | missed→met | "…is there anything else that's been worrying you…" (what_else) | (e)? b/e | ✗ |
| 5 | case002 | med | avoid_interrupting | missed→met | "When exactly did it start…" (explore_complaint) | (e)? b/e | ✗ |
| 6 | case007 | med | avoid_interrupting | missed→met | "When exactly did it start…" (explore_complaint) | (e)? b/e | ✗ |
| 7 | case012 | short | avoid_interrupting | missed→met | "…could you tell me back what the plan is?" (check_understanding) | (e)? b/e | ✗ |
| 8 | case014 | med | avoid_interrupting | missed→met | "So, in your own words, tell me what's been going on." (open_questions) | (e)? b/e | ✗ |
| 9 | case001 | med | explore_perspective | missed→met | "…anything else that's been worrying you that we haven't covered?" (what_else) | (e) | ✗ |
| 10 | case009 | long | explore_perspective | missed→met | same what_else quote | (e) | ✗ |
| 11 | case012 | short | explore_perspective | missed→met | same what_else quote | (e) | ✓ |
| 12 | case013 | short | explore_perspective | missed→met | "I can see this has been really frightening for you…" (respond_emotion) | (b) | ✗ |
| 13 | case014 | med | explore_perspective | missed→met | "What would you prefer?" (shared_plan) | (b)? b/e | ✗ |
| 14 | case009 | long | invite_questions | missed→met | "…could you tell me back what the plan is?" (check_understanding) | (b) | ✗ |
| 15 | case000 | long | open_questions | missed→met | "When exactly did it start, how severe does it get…" (explore_complaint — a closed, narrowing triple question) | (b) | ✗ |
| 16 | case001 | med | open_questions | missed→met | same closed triple question | (b) | ✗ |
| 17 | case003 | short | open_questions | missed→met | same closed triple question | (b) | ✗ |
| 18 | case004 | short | open_questions | missed→met | "Please, go on and take your time — I'm listening…" (avoid_interrupting) | (e)? e/b | ✗ |
| 19 | case006 | long | open_questions | missed→met | same closed triple question (explore_complaint) | (b) | ✓ |
| 20 | case013 | short | open_questions | missed→met | same closed triple question | (b) | ✗ |
| 21 | case004 | short | plain_language | missed→met | "Tension-type headaches like this are very common, usually harmless…" (accurate_info) | (e) | ✓ |
| 22 | case009 | long | plain_language | missed→met | same accurate_info quote | (e) | ✓ |
| 23 | case014 | med | plain_language | missed→met | same accurate_info quote | (e) | ✓ |
| 24 | case006 | long | set_tone | missed→met | "Please, go on and take your time — I'm listening, there's no rush." (avoid_interrupting) | (e) | ✓ |
| 25 | case010 | short | set_tone | missed→met | same avoid_interrupting quote | (e) | ✓ |
| 26 | case011 | long | set_tone | missed→met | same avoid_interrupting quote | (e) | ✓ |
| 27 | case013 | short | set_tone | missed→met | same avoid_interrupting quote | (e) | ✓ |
| 28 | case003 | short | shared_plan | missed→met | "we'll work through this together" (support_respect) | (b) | ✗ |
| 29 | case009 | long | shared_plan | missed→met | "Take breaks from screens, use paracetamol, and come back if it gets worse." — the **PATIENT's** words (check_understanding, patient turn) | (c) | ✗ |
| 30 | case011 | long | shared_plan | missed→met | "…could you tell me back what the plan is?" + "Take breaks from screens, use p…" (check_understanding doctor turn + patient recap) | (c)? c/e | ✗ |
| 31 | case012 | short | shared_plan | missed→met | same composite (check_understanding + patient recap) | (c)? c/e | ✗ |
| 32 | case004 | short | support_respect | missed→met | "Please, go on and take your time — I'm listening, there's no rush." (avoid_interrupting) | (e) | ✗ |
| 33 | case006 | long | support_respect | missed→met | "…let me know if anything feels uncomfortable." (explain_exam) | (e)? | ✗ |
| 34 | case008 | long | support_respect | missed→met | same avoid_interrupting quote as #32 | (e) | ✓ |
| 35 | case011 | long | support_respect | missed→met | same avoid_interrupting quote as #32 | (e) | ✓ |

No row is incomplete: every miss has a saved decision, gold label, and evidence
quote. The only data not available is the model's TIP line and any prose around
the three-line answer (not saved for the 240 run — see appendix).

## Aggregates

**By direction:** over-score 35/35 (100%). Under-score 0. This matches the
model's known profile (31.2% over-score, 100% recall) and the cross-model
finding in `app_scoring.py`: every model measured fails toward leniency.

**By criterion** (rate = misses ÷ times that criterion was truth-missed):

| Criterion | Misses | Rate | Criterion | Misses | Rate |
|---|---|---|---|---|---|
| open_questions | 6 | 6/8 = 75% | plain_language | 3 | 3/10 = 30% |
| avoid_interrupting | 6 | 6/6 = 100% | accurate_info | 2 | 2/9 = 22% |
| explore_perspective | 5 | 5/7 = 71% | invite_questions | 1 | 1/9 = 11% |
| shared_plan | 4 | 4/6 = 67% | *7 others* | 0 | 0/46 |
| support_respect | 4 | 4/4 = 100% | | | |
| set_tone | 4 | 4/7 = 57% | | | |

Concentration is extreme: **3 criteria account for 49% of misses
(open_questions, avoid_interrupting, explore_perspective: 17/35); 5 criteria
for 71% (add shared_plan, support_respect: 25/35)** — while 7 of the 16
criteria (intro_self, explore_complaint, what_else, respond_emotion,
explain_exam, check_understanding, safety_net) have **zero** misses in 46
opportunities. The zero-miss criteria are exactly the ones whose snippet
content is distinctive; the missed ones are the diffuse "manner" criteria plus
the criterion-pairs that read alike.

**By failure-mode tag:**

| Tag | Rows | Share |
|---|---|---|
| (e) questionable gold — firm | 15 | 43% |
| (e)? uncertain (incl. 6× avoid_interrupting b/e, 2× shared_plan c/e, #18, #33) | 10 | 29% |
| (b) evidence found but judged wrong — firm | 8 | 23% |
| (b)? uncertain | 1 | 3% |
| (c) instruction violated (patient speech credited) — firm | 1 | 3% |
| (a) evidence missed / (d) format | 0 | — |

Firm model errors: **10/35 (29%)**. Gold-label-questionable (firm + uncertain):
**25/35 (71%)**. If a re-audit sided with the model on all 25, measured
accuracy against corrected gold would be (205+25)/240 = **95.8%**; if on none,
85.4% stands. The true number is decision-relevant and unknown until the
(e) rows are re-audited (list below).

**By transcript / length tercile** (rate = misses ÷ truth-missed decisions in
that bucket):

| Tercile | Misses | Rate | Worst cases |
|---|---|---|---|
| short | 12 | 12/48 = 25% | case001 & case009: 4 misses each; |
| med | 10 | 10/38 = 26% | 8 further cases: 3 each; every case |
| long | 13 | 13/26 = **50%** | has ≥1 miss |

Long transcripts miss at double the rate — but by construction, length here ∝
number of met snippets, so "long" really means "more other-criterion material
available to mis-credit". It is a confusable-material effect, not an attention/
length effect, and real consultations (which contain far more off-rubric talk
than these ~200-word scripts) sit well outside this range.

**Verifier cross-reference:** the second pass (`VERIFY-REPORT.txt`) rejected 22
of these 35 and confirmed 13. Twelve of the 13 confirmations are rows tagged
(e) — the sceptical verifier independently sides with the grader almost
exactly where the gold label is questionable (the one exception is #19). That
is corroborating evidence for the (e) tags, and it also means the verify
pass's residual 13/112 over-score is mostly label noise, not verifier failure.

## Narrative

**Failure mode 1 — cross-criterion crediting (all 35 rows, two distinct
causes).** The model's single behavior pattern is: find a real, on-transcript
clinician quote and credit it against the criterion asked about, even though
the quote belongs to a different criterion. It splits by whether the quote
*genuinely* satisfies the asked criterion:

- **Label noise, not model error — the (e) cluster (15 firm + 10 uncertain,
  up to 71%).** The gold set derives "missed" purely from *snippet omission*,
  but for diffuse criteria another included snippet often genuinely satisfies
  the ask: "take your time… there's no rush" *is* an unrushed tone (set_tone,
  4/4 verifier-confirmed); the accurate_info sentence *is* plain language
  (3/3 confirmed); "anything else that's been worrying you" *does* ask what
  worries the patient (explore_perspective). The README's caveat ("one snippet
  occasionally satisfies another criterion") is precisely this, and it is
  concentrated where criteria are manner-based rather than content-based.
  **Not prompt-fixable, not fine-tune-worthy — fix the benchmark**: re-audit
  the 25 rows below, and/or regenerate gold with an exclusion rule (when
  criterion X is labeled missed, don't include snippets that plausibly satisfy
  X), and/or score the manner criteria (set_tone, support_respect,
  plain_language) by a different mechanism than quote-evidence.
  A special sub-case is **avoid_interrupting (6/6 missed→met, 100%)**: it is
  an *absence* behavior. In transcripts that contain no interruption, "did the
  clinician avoid interrupting?" is arguably met by default, and no quote can
  ever prove it under the "done REQUIRES a quote" rule. As gold-constructed it
  can only be scored met by quoting one specific line. That is a rubric-design
  question for the director (allow N/A / default-met?), not a model defect.
  Fine-tuning against these labels as they stand would *teach the model to
  reject genuinely supportive quotes* — the recall-collapse failure that
  disqualified Gemma-3-4B.

- **Real model error — the (b)/(c) cluster (10 firm rows, 29%).** Here the
  quote clearly does not show the behavior: a closed, narrowing triple
  question credited as *open* questions (5 of the 6 open_questions rows —
  the single biggest genuine defect); teach-back credited as inviting
  questions (#14); "we'll work through this together" credited as a plan
  (#28); and one outright instruction violation — the **patient's** plan
  recap credited to the clinician (#29, with #30–31 partially the same). This
  is the known deficiency `app_scoring.py` names: insufficient scepticism
  about whether a quote shows *this specific* behavior.
  Prompt-level fixes have already been measured: few-shot negative
  calibration made the 240 score *worse* (81.7%), and the verify pass fixes
  22 of the 35 at 1.68× cost but destroys 11 recall points (100→91.4%). If a
  fine-tune happens, **this is the slice**: hard-negative pairs for
  confusable criteria — closed-vs-open question openers, teach-back vs
  invite_questions vs shared_plan, patient-said vs clinician-said, and
  warm-manner lines vs specific asks. But note the ceiling: 10 firm errors on
  240 decisions ≈ 4 accuracy points.

**Recommended order of operations:** re-audit the 25 flagged gold labels
first. The corrected baseline lands somewhere in 85.4–95.8%; if it comes out
above ~92%, the remaining genuine errors (~10, half of them one pattern:
closed-question-as-open) are likely cheaper to address with targeted rubric
wording or a narrower verifier than with a fine-tune. Fine-tuning before the
re-audit would optimize against labels that are ~29–71% noise on exactly the
rows being trained.

## (e)-tagged rows for gold re-audit (25)

> Actionable version: `gold_audit.md` is a fill-in rulings sheet covering these
> rows (expanded to 27 for label-consistency), and `audit_recompute.py`
> recomputes every saved model's bars from the rulings.

Firm (e) — the quoted line arguably satisfies the criterion as worded:

- **#1, #2** (case001, case007 · accurate_info): "muscles around your head
  tightening up — nothing dangerous" + options line — accurate, appropriate
  info about condition and options, just not via the designated snippet.
- **#9, #10, #11** (case001, case009, case012 · explore_perspective): "is
  there anything else that's been *worrying* you" — the rubric's own
  good-looks-like is "asks … what worries them".
- **#21, #22, #23** (case004, case009, case014 · plain_language): the
  accurate_info sentence is itself plain-language explanation.
- **#24–#27** (case006/010/011/013 · set_tone): "take your time — I'm
  listening, there's no rush" vs good-looks-like "appears unhurried". All four
  verifier-confirmed.
- **#32, #34, #35** (case004, case008, case011 · support_respect): same warm
  line vs "warm, respectful language; conveys the patient is heard" — a
  "throughout" criterion nearly any warm line can evidence.
- **#18** (case004 · open_questions, *uncertain*): "please, go on and take
  your time" vs good-looks-like "invites the patient to elaborate" — though it
  is not a question and not the opening.
- **#33** (case006 · support_respect, *uncertain*): "let me know if anything
  feels uncomfortable" — concern/comfort, but during an exam narration.

Uncertain (e) — tagged b/e or c/e, gold defensible but so is the model:

- **#3–#8** (avoid_interrupting, 6 rows): absence-behavior criterion; no
  interruption occurs anywhere in these transcripts, so "met" is a reasonable
  human answer even though every cited quote fails to show "giving space".
- **#30, #31** (case011, case012 · shared_plan): construction artifact — when
  check_understanding is met but shared_plan is missed, the transcript shows
  the doctor saying "just so I know I've *explained it clearly*, tell me back
  the plan" and the patient reciting a full plan the doctor never stated. The
  transcript internally asserts a plan was discussed; a human could
  reasonably score met. (#29 shares the artifact but is tagged (c) because the
  model quoted purely patient speech, which the prompt categorically forbids.)

## Post-audit results (2026-09-01)

Bilal ruled on all 27 disputed labels (`gold_audit.md`): **16 met** (set_tone,
support_respect, plain_language, accurate_info, explore_perspective-via-
what_else groups), **1 missed** (case004 open_questions), **10 na** (all
avoid_interrupting — no interruption is ever authored, so unscorable — and all
shared_plan teach-back-artifact rows). `audit_recompute.py` against those
rulings (n = 230 after exclusions):

| Run | Accuracy | Over-score | Recall |
|---|---|---|---|
| **Qwen3.5-4B no-think (ships)** | 85.4 → **96.1** | 31.2 → **10.5** | 100 → **100** |
| FM adapter strict_grader | 98.3 → 94.8 | 3.6 → 0.0 | 100 → 91.7 |
| Qwen3.5-4B + verifier | 90.0 → 93.0 | 11.6 → 1.2 | 91.4 → 89.6 |
| Qwen2.5-7B | 79.2 → 85.2 | 36.6 → 26.7 | 93.0 → 92.4 |

Consequences:

1. **No fine-tune.** The shipped 4B's true error rate is 9/230 (3.9%), and 6
   of the 9 are one pattern: crediting a closed question ("when exactly did it
   start, how severe…") as an *open-ended* one. The remaining 3: two
   explore_perspective (respond_emotion / "what would you prefer" quotes), one
   invite_questions (teach-back quote). All over-scores; recall stays 100%.
2. **The strict-grader FM adapter's 98.3% was label-noise fit**: on corrected
   gold it *drops* to 94.8% with recall down to 91.7% — it had learned to say
   "missed" on rows that were actually met. The 4B now leads outright.
3. **The second-pass verifier is no longer worth it as a blanket pass**: on
   corrected labels it subtracts accuracy (96.1 → 93.0), because most of what
   it "fixed" was label noise. If the open_questions confusion is attacked at
   all, scope it there (prompt wording defining open vs closed, or a verifier
   only on that criterion).
4. **v2 generator fixes stand** (for the next benchmark, not this one): author
   real interruptions for avoid_interrupting; only include teach-back when a
   plan is actually stated; exclusion rule so no included snippet satisfies an
   omitted criterion's label.

## Appendix — regeneration

Everything above regenerates from (venv per README; each full run is ~30 min
on the Air, per the memory note: build/run on Air, not the mini):

```bash
python bench_scoring.py --model mlx-community/Qwen3.5-4B-4bit --no-think   # decisions
python bench_verify.py  --model mlx-community/Qwen3.5-4B-4bit --no-think   # + evidence quotes
```

The gold set is already on disk and matches the saved run; regenerating it
(`generate_scoring_dataset.py --n 15`, seed 7) is only needed if `data/` is
lost. The full raw model text (RESULT/EVIDENCE/TIP lines) for the 240 set is
not saved by any current script — `bench_scoring.py` would need to persist
`raw` the way `bench_realistic.py` does (a one-line change, not made here:
this analysis is read-only on the harness).
