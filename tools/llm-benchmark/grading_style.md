# The grading standard — codified from Bilal's rulings

Source: 64 blind calibration rulings (2026-09-03, `calibration/sheets/`) and
27 gold-audit rulings (2026-09-01, `gold_audit.md`). This file is the ground
truth for `gen_finetune_v4.py`'s labels and the source for the candidate
prompt block below. Each rule cites the ruling(s) it comes from.

## Rules

1. **"Done" means performed fully and sincerely — a token gesture is partial
   at best.** A flung "Anything else?" after the prescription is partial, not
   done. [cough what_else=partial; headache what_else=partial;
   headache invite_questions=partial]
2. **"Throughout" criteria are holistic.** One warm line in an otherwise
   brisk visit is partial for support_respect; sustained warmth is met even
   without a signature phrase. [rash support_respect=partial vs headache
   support_respect=met; audit group C]
3. **Patient speech never credits the clinician.** Not their volunteered
   fears, not their plan recap, not their self-summary — even when the
   clinician says "you've got it". Confirming a patient's own summary is not
   checking understanding. [audit shared_plan case009=(c); headache
   check_understanding=missed; rash check_understanding=missed]
4. **A missed emotional cue costs credit even if a later cue is handled.**
   Validating the second worry after brushing past the first is partial for
   respond_emotion. [backpain respond_emotion=partial]
5. **Interrupting poisons exploration.** A criterion-complete interrogation
   conducted by cutting the patient off is missed for explore_complaint —
   covering dimensions does not survive severing the story. [cough
   explore_complaint=missed vs rash explore_complaint=met]
6. **Introduction needs name AND role.** "Hi there, I'm Dr Marsh" alone is
   missed; "I'm Dr Okafor, one of the GPs here" is met. Warm greeting with no
   name is missed. [rash intro_self=missed; backpain intro_self=met;
   headache intro_self=missed (corrected)]
7. **Open questions are about how the consultation BEGINS.** A closed opener
   ("So it's about a rash?") followed by an open-ish question mid-visit is
   still missed; a closed multi-part battery is never an open question.
   [rash open_questions=missed; audit group G=missed]
8. **Deflecting a direct patient question voids information credit.**
   "Everything in moderation, you know your body best" in response to a real
   medical question is missed for accurate_info; so is confident reassurance
   with no examination or reasoning behind it. [headache accurate_info=missed]
9. **Safety-netting needs concrete red flags plus when/how to seek help.**
   "Book back in whenever you like" is missed; "come back if it's not gone in
   a month" alone is missed; named red flags + "A&E same day" is met.
   [headache safety_net=missed; cough safety_net=missed; rash safety_net=met]
10. **Aggregate criteria (explore_complaint, plain_language) are judged on
    the whole visit** — no single quote can prove or disprove them. This is
    why the second-pass verifier must skip them. [calibration FINDINGS]
11. **N/A is real**: a criterion that cannot occur (no exam happened) is
    excluded, not failed. [headache explain_exam=na]

## Candidate prompt block (the cheap experiment)

Splice into the scoring rules of `SCORING_PREFIX` and measure before/after on
the calibration gold:

> - "done" requires the behavior performed FULLY and sincerely. A token
>   gesture — a flung "anything else?", a perfunctory "does that make
>   sense?" — is "partial" at best, never "done".
> - Confirming the patient's own summary or repeating their words back is
>   NOT checking understanding or exploring their perspective. Only what the
>   CLINICIAN initiates counts.
> - If the clinician interrupts or deflects the patient's questions, do not
>   credit exploration or information-giving for material covered that way.

## Known limits

Derived from 91 rulings by one rater on 4 LLM-authored + 15 snippet-built
transcripts. Rules 4 and 5 rest on single rulings each (marked). Before any
adapter trained on this ships, validate against fresh human transcripts that
were scored blind — see `calibration/README.md`.
