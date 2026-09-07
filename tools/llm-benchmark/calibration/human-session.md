# Human transcript session — the final validation (and the v5 seed)

~40 minutes with one partner. Produces the first genuinely human gold
transcripts: validates the shipped config on real dialogue, and doubles as
the raw material for any future fine-tune. No LLM writes or edits a word of
these transcripts.

## How to produce each transcript (~10 min each)

Improvise aloud from the cards below — don't script it. Capture either way:
- **Typed-live** (easiest): a shared doc, each person types their own lines
  as `Doctor: …` / `Patient: …`. Messy is good; don't clean it up.
- **Recorded**: voice memo, then transcribe however; keep the speaker labels.

Save as `calibration/transcripts/h1_utis.txt`, `h2_palpitations.txt`,
`h3_insomnia.txt` (the `h` prefix marks the human batch). Rules: no reusing
phrasings from the four LLM-drafted visits; the patient player should NOT
read the rubric first; imperfections, interruptions, and rambling are
features.

## Scenario cards

Give the patient player only their card. The doctor player follows the
quality profile from memory — what actually comes out of your mouth is what
gets graded, not what you intended.

### 1 — "h1" · recurrent UTIs · GOOD consultation
- **Patient card:** third UTI in five months, burning + frequency again since
  yesterday. Embarrassed to keep coming in. Secretly worried it means
  something is wrong with your kidneys. If given room, mention your mother
  had kidney failure. Ask at some point: "do I need a scan?"
- **Doctor profile:** do everything properly — name+role, comfort, open
  start, thorough history, invite other concerns, dig into her worry,
  respond to the embarrassment, explain any examination, plain-language
  explanation, options + her preference, teach-back, concrete red flags,
  final questions.

### 2 — "h2" · palpitations · RUSHED consultation
- **Patient card:** heart races at night, few minutes at a time, started ~3
  weeks ago. Frightened it's a heart attack coming — your brother had one at
  fifty. You drink 4–5 coffees a day but don't volunteer it unless asked.
  Try to tell the full story; push your fear at least twice.
- **Doctor profile:** competent medicine, terrible manner — no intro, closed
  rapid-fire questions, cut the patient off at least twice, brush past the
  brother fear, jargon ("benign ectopy, likely catecholaminergic"), issue a
  plan without options, no teach-back, vague "come back if it's worse",
  abrupt end.

### 3 — "h3" · can't sleep · MIXED consultation
- **Patient card:** three months of 3am waking, exhausted, work suffering.
  You suspect it started when your partner moved out. You want sleeping
  pills and say so early. Get a bit tearful once, if it flows.
- **Doctor profile:** warm and unhurried, listens well, responds to the
  tears — but then: no real exploration of the breakup lead, explains
  little, deflects the sleeping-pill question without answering it, gives
  advice rather than a shared plan, no teach-back, no red flags, but does
  invite final questions.

## After the transcripts exist (the protocol — order matters)

1. `python3 calibration.py sheet` → Bilal scores all sheets BLIND (before any
   judge output; guided session with Claude available — evidence surfaced
   neutrally, no recommendations).
2. Claude scores the same transcripts independently (recorded before any
   judge run).
3. **Adjudicate**: for every row where the two raters differ, discuss and
   settle a consensus label. Consensus gold has less noise than either rater
   — this is what raises the measurement ceiling past ~86%.
4. On the Air: `python3 calibration.py judge` then `verify` then `report` —
   the shipped config's first score on genuinely human dialogue.
5. Read against the pre-registered expectation: the LLM-drafted set said
   81–84% with the scoped verifier. Roughly that on human dialogue →
   validated, ship with confidence. Meaningfully below → the gap analysis
   becomes the v5 fine-tune's target slice, with these transcripts as the
   seed of its training distribution (and rows never trained on stay the
   exam).

Caveat noted up front: Claude authored these scenario cards, so
Claude-as-second-rater carries mild intent-anchoring; Bilal's blind read of
the actual transcript remains the primary gold, and adjudication is
transcript-text-only.
