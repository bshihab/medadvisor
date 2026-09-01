# Gold-label audit sheet — 240-decision scoring set

Companion to `error_analysis.md`. 27 disputed gold labels, grouped by pattern.
Rule on each row, then run `python audit_recompute.py` to see every saved
model's corrected bars (it reads this file; nothing in `results/` or `data/`
is modified).

**How to rule:** replace the `?` after `RULING:` with one of:

- `met` — the transcript genuinely demonstrates this behavior; the gold label
  was wrong.
- `missed` — the gold label stands.
- `na` — this decision can't be fairly scored in this case; exclude it from
  scoring **for all models**.
- `?` — not ruled yet; the current gold label is kept.

**What you are ruling on:** the *transcript vs the label* — "would a careful
human examiner reading this transcript call the behavior demonstrated?" — NOT
whether the 4B's particular quote was good. Rows where the model's own quote
was bad even though the label is disputed are flagged. Consistency matters: a
ruling's logic should apply to every row in its group, since the recompute
applies label corrections to all models alike.

The script parses any line of the form `- [caseNNN · criterion_id] RULING: x`,
so you can add rows in the same format if you want to audit a label not listed
here (e.g. case014 · explore_perspective, "What would you prefer?" — kept out
as a firm model error, but it's your call).

---

## Group A — avoid_interrupting (6 rows): absence behavior, criterion-wide

**Criterion:** "Did the clinician avoid interrupting and give the patient
space to speak?" · good looks like: "Lets the patient finish; does not cut
them off."

These are ALL six gold-missed avoid_interrupting decisions in the set. By
construction, no transcript in the set contains an interruption — gold says
"missed" only because the explicit give-space line ("Please, go on and take
your time — I'm listening, there's no rush.") was omitted from these six cases.

- Case for `met`: it's an *absence* behavior. The patient is never cut off
  anywhere in these transcripts, so "avoided interrupting" is true by default.
- Case for `missed`: under the app's quote-required scheme ("done REQUIRES a
  direct supporting quote"), nothing positive is demonstrable.
- Case for `na`: with no interruption *and* no give-space line, the transcript
  contains no evidence either way — arguably unscorable.

One philosophy should cover all six. (This is also a rubric-design question
for the director: if you rule `met` or `na` here, the criterion likely needs
the same treatment in the app.)

- [case000 · avoid_interrupting] RULING: na
- [case001 · avoid_interrupting] RULING: na
- [case002 · avoid_interrupting] RULING: na
- [case007 · avoid_interrupting] RULING: na
- [case012 · avoid_interrupting] RULING: na
- [case014 · avoid_interrupting] RULING: na

## Group B — set_tone (4 rows): "no rush" line present

**Criterion:** "Did the clinician set a comfortable, unrushed tone (e.g.
acknowledging privacy/comfort)?" · good: "Appears unhurried; attends to the
patient's comfort and privacy."

Gold-missed because the official snippet ("Please make yourself comfortable —
we've got plenty of time and it's just the two of us in here.") is absent. But
each of these transcripts contains: **"Please, go on and take your time — I'm
listening, there's no rush."**

- Case for `met`: "take your time… there's no rush" is an unrushed tone in so
  many words. The sceptical second-pass verifier independently confirmed all
  four.
- Case for `missed`: the line addresses pacing mid-history, not comfort/privacy
  at the outset; the official snippet also covers privacy ("just the two of
  us"), which nothing else does.

- [case006 · set_tone] RULING: met
- [case010 · set_tone] RULING: met
- [case011 · set_tone] RULING: met
- [case013 · set_tone] RULING: met

## Group C — support_respect (4 rows): warm lines present

**Criterion:** "Did the clinician convey support, concern, and respect
throughout?" · good: "Warm, respectful language; conveys that the patient is
heard."

Gold-missed because the official snippet ("You've done exactly the right thing
coming in, and we'll work through this together.") is absent. But these
transcripts contain **"Please, go on and take your time — I'm listening,
there's no rush."** (all four) and, in case006/008/011, also **"…let me know
if anything feels uncomfortable."**

- Case for `met`: "I'm listening" conveys the patient is heard; "let me know if
  anything feels uncomfortable" attends to comfort and concern. A "throughout"
  criterion is exactly the kind almost any warm line can evidence.
- Case for `missed`: those lines are already the designated evidence for
  avoid_interrupting / explain_exam; crediting them twice makes the manner
  criteria unfalsifiable.

- [case004 · support_respect] RULING: met
- [case006 · support_respect] RULING: met
- [case008 · support_respect] RULING: met
- [case011 · support_respect] RULING: met

## Group D — plain_language (3 rows): plainly-worded explanation present

**Criterion:** "Did the clinician explain things in plain language, avoiding
jargon?" · good: "Uses everyday words; defines any necessary medical terms."

Gold-missed because the official snippet ("In simple terms, it's the muscles
around your head tightening up — nothing dangerous.") is absent. But each
transcript contains the accurate_info sentence: **"Tension-type headaches like
this are very common, usually harmless, and often linked to stress, screen
time, or poor sleep."**

- Case for `met`: that sentence is an everyday-words explanation; the one
  semi-technical term ("tension-type") is immediately unpacked by context.
  Verifier confirmed all three.
- Case for `missed`: "tension-type headaches" is undefined jargon; the official
  snippet is what *defining in simple terms* looks like.

- [case004 · plain_language] RULING: met
- [case009 · plain_language] RULING: met
- [case014 · plain_language] RULING: met

## Group E — accurate_info (2 rows): condition + options info present

**Criterion:** "Did the clinician give accurate, appropriate information about
the condition and options?" · good: "Information given is correct and
relevant; avoids false reassurance or overstated certainty."

Gold-missed because the official accurate_info sentence is absent. But these
transcripts contain **"In simple terms, it's the muscles around your head
tightening up — nothing dangerous."** (plain_language) and **"There are a
couple of options — we could try regular screen breaks and simple pain relief
first, or start a preventer."** (shared_plan).

- Case for `met`: mechanism of tension headache + treatment options = accurate,
  appropriate information about condition and options. Verifier confirmed both.
- Case for `missed`: "nothing dangerous" borders on the false reassurance the
  good-looks-like warns about, and no epidemiology/causes are given.

- [case001 · accurate_info] RULING: met
- [case007 · accurate_info] RULING: met

## Group F — explore_perspective (3 rows): "worrying you" question present

**Criterion:** "Did the clinician explore the patient's perspective — their
ideas, fears, and expectations?" · good: "Asks what the patient thinks is
going on, what worries them, or what they're hoping for."

Gold-missed because the official snippet ("What do you think might be causing
it, and is there anything in particular you're worried it could be?") is
absent. But each transcript contains the what_else line: **"Before we move on,
is there anything else that's been worrying you that we haven't covered?"**

- Case for `met`: it literally asks what has been *worrying* the patient — the
  rubric's own good-looks-like wording.
- Case for `missed`: it's an agenda-completeness question ("anything else…we
  haven't covered"), not an exploration of ideas/fears/expectations about the
  presenting problem; the patient answers "No, I think that's everything."

- [case001 · explore_perspective] RULING: met
- [case009 · explore_perspective] RULING: met
- [case012 · explore_perspective] RULING: met

## Group G — open_questions (1 row): "go on" invitation present

**Criterion:** "Did the clinician begin with open-ended questions and let the
patient tell their story?" · good: "Starts broad before narrowing; invites the
patient to elaborate."

Gold-missed in case004; the official snippet ("So, in your own words, tell me
what's been going on.") is absent, but the transcript contains **"Please, go
on and take your time — I'm listening, there's no rush."**

- Case for `met`: "go on" invites the patient to elaborate — half of the
  good-looks-like.
- Case for `missed`: it isn't a question, and the criterion is about how the
  consultation *begins*; the other five open_questions misses (where the model
  credited the closed "when did it start / how severe" battery) are firm model
  errors and are not audited here.

- [case004 · open_questions] RULING: missed

## Group H — shared_plan (4 rows): teach-back implies a plan existed

**Criterion:** "Did the clinician discuss a clear plan and involve the patient
in decisions?" · good: "Lays out next steps and invites the patient's
preferences."

Gold-missed (official options-and-preference snippet absent), but each of
these transcripts contains the check_understanding exchange: **D: "Just so I
know I've explained it clearly, could you tell me back what the plan is?" /
P: "Take breaks from screens, use paracetamol, and come back if it gets
worse."** — a construction artifact: the doctor asserts a plan was explained
and the patient recites one, yet no plan statement exists on-transcript.

- Case for `met`: the transcript internally asserts the plan discussion
  happened; a human reader would infer it did.
- Case for `missed`: the clinician never lays out steps or invites preference
  in the text; "involve the patient in decisions" is undemonstrated.
- Case for `na`: the transcript is self-contradictory here by construction —
  arguably unscorable.

Flag: in case003 the 4B's quote was "we'll work through this together" and in
case009 it quoted the *patient's* recap — both bad quotes regardless of your
ruling. The label question is the same for all four rows anyway.

- [case003 · shared_plan] RULING: na
- [case009 · shared_plan] RULING: na
- [case011 · shared_plan] RULING: na
- [case012 · shared_plan] RULING: na

---

When done: `python audit_recompute.py` (add `--audit <file>` only if you moved
this sheet). Unruled `?` rows are counted and kept at their current gold label.
