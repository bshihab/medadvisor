# Blind scoring sheet — rash_visit

Score every criterion from the transcript below, BEFORE looking
at any judge output. Replace each `?` with: met / partial / missed / na.
The app treats partial and missed both as not-met; na = criterion
does not apply to this consultation.

## Transcript

```
Doctor: Hi there, I'm Dr Marsh — sorry, the system's running slow today. Right. So it's about a rash?
Patient: Yeah. It's on my arms mostly, inside the elbows, and a bit on my neck. It's been maybe two months, on and off.
Doctor: Okay. Itchy?
Patient: Really itchy. Especially at night, I scratch in my sleep, I wake up and it's all raw.
Doctor: And you said on and off — does anything set it off that you've noticed?
Patient: Um, I thought maybe the new washing powder? We switched brands around then. But I switched back two weeks ago and it's still happening. Hot showers definitely make the itching worse after.
Doctor: Any new soaps, perfumes, pets?
Patient: No pets. My girlfriend did buy some scented candles but I wouldn't have thought—
Patient: Probably not the candles, no, unless you're handling them a lot. Any of this run in the family — eczema, asthma, hay fever?
Doctor: Sorry — that was me asking, the family history bit. Eczema, asthma, hay fever — any of those in the family?
Patient: Oh right. Yeah, my mum has asthma, and I had eczema as a kid apparently, behind my knees. I grew out of it.
Doctor: Well, that's quite telling. Let me have a look at your arms... okay, yes. Can I roll your sleeve up further? I'm just looking at the pattern of it, and I'll check your neck too.
Patient: Sure. It looks worse than usual today actually.
Doctor: So this looks very much like eczema — atopic dermatitis is the formal name. Dry, itchy, inflamed patches in the skin creases, the family history, the childhood eczema — it fits together. It hasn't come back because of anything you did wrong; it often resurfaces in adults, especially with stress or in winter.
Patient: Huh. I thought you couldn't get it again once you grew out of it.
Doctor: It can lie low for years and come back, unfortunately. The good news is it's very treatable. So — two-part plan, tell me what you think. First, moisturiser, a lot of it, more than feels reasonable, on the whole area twice a day even when it looks fine — that's the base layer. Second, a steroid cream for the angry patches, a mild one, thin layer once a day for a week or two at a time. Some people worry about steroid creams — how do you feel about that?
Patient: I mean, if it stops the itching I'll take it. My girlfriend might have opinions but she's not the one scratching.
Doctor: Ha — well, the doses in these creams are small and we're using it in short bursts, so I'm comfortable, and you can send her to me if she has questions. Cooler showers will help too. I'll put both on a prescription now.
Patient: Okay, great.
Doctor: If it starts weeping, crusting yellow, or gets suddenly a lot more red and painful, that can mean it's infected — come back quickly for that, don't wait it out. Same if it's not clearly better after three weeks of doing all this.
Patient: Weeping or crusty, come back. Okay.
Doctor: Prescription's done. The receptionist can book your follow-up if you want one in the diary now. Bye now.
Patient: Oh — I did have one more... never mind, it's fine. Thanks doctor.
```

## Scores

**intro_self** — Did the clinician introduce themselves and explain their role?
  *good looks like: States name and role and greets the patient.*
- [rash_visit · intro_self] SCORE: ?

**set_tone** — Did the clinician set a comfortable, unrushed tone (e.g. acknowledging privacy/comfort)?
  *good looks like: Appears unhurried; attends to the patient's comfort and privacy.*
- [rash_visit · set_tone] SCORE: ?

**open_questions** — Did the clinician begin with open-ended questions and let the patient tell their story?
  *good looks like: Starts broad before narrowing; invites the patient to elaborate.*
- [rash_visit · open_questions] SCORE: ?

**explore_complaint** — Did the clinician explore the presenting complaint thoroughly (onset, duration, severity, associated symptoms, what's been tried)?
  *good looks like: Characterizes the complaint across its key dimensions.*
- [rash_visit · explore_complaint] SCORE: ?

**avoid_interrupting** — Did the clinician avoid interrupting and give the patient space to speak?
  *good looks like: Lets the patient finish; does not cut them off.*
- [rash_visit · avoid_interrupting] SCORE: ?

**what_else** — Did the clinician check for additional concerns ('is there anything else?')?
  *good looks like: Explicitly invites further concerns before moving on.*
- [rash_visit · what_else] SCORE: ?

**explore_perspective** — Did the clinician explore the patient's perspective — their ideas, fears, and expectations?
  *good looks like: Asks what the patient thinks is going on, what worries them, or what they're hoping for.*
- [rash_visit · explore_perspective] SCORE: ?

**respond_emotion** — Did the clinician acknowledge and respond to the patient's emotions?
  *good looks like: Names or validates the emotion; responds rather than rushing past it.*
- [rash_visit · respond_emotion] SCORE: ?

**support_respect** — Did the clinician convey support, concern, and respect throughout?
  *good looks like: Warm, respectful language; conveys that the patient is heard.*
- [rash_visit · support_respect] SCORE: ?

**explain_exam** — If a physical exam occurred, did the clinician explain what they were doing and check comfort? (N/A if no exam.)
  *good looks like: Narrates the exam and minimizes surprise/discomfort verbally.*
- [rash_visit · explain_exam] SCORE: ?

**plain_language** — Did the clinician explain things in plain language, avoiding jargon?
  *good looks like: Uses everyday words; defines any necessary medical terms.*
- [rash_visit · plain_language] SCORE: ?

**accurate_info** — Did the clinician give accurate, appropriate information about the condition and options?
  *good looks like: Information given is correct and relevant; avoids false reassurance or overstated certainty.*
- [rash_visit · accurate_info] SCORE: ?

**shared_plan** — Did the clinician discuss a clear plan and involve the patient in decisions?
  *good looks like: Lays out next steps and invites the patient's preferences.*
- [rash_visit · shared_plan] SCORE: ?

**check_understanding** — Did the clinician check the patient's understanding (e.g. teach-back)?
  *good looks like: Asks the patient to restate the plan in their own words.*
- [rash_visit · check_understanding] SCORE: ?

**safety_net** — Did the clinician safety-net (what to watch for, when and how to seek help)?
  *good looks like: Gives explicit, actionable return precautions.*
- [rash_visit · safety_net] SCORE: ?

**invite_questions** — Did the clinician invite final questions before closing?
  *good looks like: Explicitly asks what questions the patient has.*
- [rash_visit · invite_questions] SCORE: ?
