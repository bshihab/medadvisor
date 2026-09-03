# Blind scoring sheet — cough_visit

Score every criterion from the transcript below, BEFORE looking
at any judge output. Replace each `?` with: met / partial / missed / na.
The app treats partial and missed both as not-met; na = criterion
does not apply to this consultation.

## Transcript

```
Doctor: Yes, come in. Cough, is it?
Patient: Uh, yes — hi. It's been going on about three weeks now, it started when—
Doctor: Any fever?
Patient: Um, maybe the first few days? I felt hot but I didn't actually check with a—
Doctor: Coughing anything up? Phlegm? What colour?
Patient: A little bit in the mornings, sort of clear, whitish maybe. Mostly it's dry though, especially at night, it's my wife who made me come in actually because I'm keeping her—
Doctor: Smoker?
Patient: I quit four years ago. I did smoke for about ten years before that.
Doctor: Short of breath? Chest pain?
Patient: Not really short of breath. Sometimes the coughing fits make my chest sore, like a pulled muscle feeling. I did want to ask about—
Doctor: Any blood in what you cough up?
Patient: No. No blood. But I was going to say, my dad had lung cancer, so this has been on my mind a lot, and three weeks feels like a long time for a—
Doctor: Three weeks is nothing for a cough, they can go eight weeks after a virus. Shirt up, let me listen. Big breaths. In. Out. Again. Right. Chest's clear.
Patient: Okay... clear meaning...?
Doctor: Meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles.
Patient: Right. Sorry, hyper-what? Is that — should I be doing anything for it?
Doctor: I'll put you on a salbutamol inhaler, two puffs when it's bad. Pharmacy will show you how to use it. Anything else?
Patient: Um. I guess — no. My wife wanted me to ask about a chest X-ray but you're saying it's fine, so.
Doctor: If it's not gone in another month you can book in again and we'll think about imaging then. I've got a full waiting room, so. Prescription's sent through.
Patient: Okay. Thanks, I suppose.
Doctor: Take care now.
```

## Scores

**intro_self** — Did the clinician introduce themselves and explain their role?
  *good looks like: States name and role and greets the patient.*
- [cough_visit · intro_self] SCORE: missed

**set_tone** — Did the clinician set a comfortable, unrushed tone (e.g. acknowledging privacy/comfort)?
  *good looks like: Appears unhurried; attends to the patient's comfort and privacy.*
- [cough_visit · set_tone] SCORE: missed

**open_questions** — Did the clinician begin with open-ended questions and let the patient tell their story?
  *good looks like: Starts broad before narrowing; invites the patient to elaborate.*
- [cough_visit · open_questions] SCORE: missed

**explore_complaint** — Did the clinician explore the presenting complaint thoroughly (onset, duration, severity, associated symptoms, what's been tried)?
  *good looks like: Characterizes the complaint across its key dimensions.*
- [cough_visit · explore_complaint] SCORE: missed

**avoid_interrupting** — Did the clinician avoid interrupting and give the patient space to speak?
  *good looks like: Lets the patient finish; does not cut them off.*
- [cough_visit · avoid_interrupting] SCORE: missed

**what_else** — Did the clinician check for additional concerns ('is there anything else?')?
  *good looks like: Explicitly invites further concerns before moving on.*
- [cough_visit · what_else] SCORE: partial

**explore_perspective** — Did the clinician explore the patient's perspective — their ideas, fears, and expectations?
  *good looks like: Asks what the patient thinks is going on, what worries them, or what they're hoping for.*
- [cough_visit · explore_perspective] SCORE: missed

**respond_emotion** — Did the clinician acknowledge and respond to the patient's emotions?
  *good looks like: Names or validates the emotion; responds rather than rushing past it.*
- [cough_visit · respond_emotion] SCORE: missed

**support_respect** — Did the clinician convey support, concern, and respect throughout?
  *good looks like: Warm, respectful language; conveys that the patient is heard.*
- [cough_visit · support_respect] SCORE: missed

**explain_exam** — If a physical exam occurred, did the clinician explain what they were doing and check comfort? (N/A if no exam.)
  *good looks like: Narrates the exam and minimizes surprise/discomfort verbally.*
- [cough_visit · explain_exam] SCORE: missed

**plain_language** — Did the clinician explain things in plain language, avoiding jargon?
  *good looks like: Uses everyday words; defines any necessary medical terms.*
- [cough_visit · plain_language] SCORE: missed

**accurate_info** — Did the clinician give accurate, appropriate information about the condition and options?
  *good looks like: Information given is correct and relevant; avoids false reassurance or overstated certainty.*
- [cough_visit · accurate_info] SCORE: missed

**shared_plan** — Did the clinician discuss a clear plan and involve the patient in decisions?
  *good looks like: Lays out next steps and invites the patient's preferences.*
- [cough_visit · shared_plan] SCORE: partial

**check_understanding** — Did the clinician check the patient's understanding (e.g. teach-back)?
  *good looks like: Asks the patient to restate the plan in their own words.*
- [cough_visit · check_understanding] SCORE: missed

**safety_net** — Did the clinician safety-net (what to watch for, when and how to seek help)?
  *good looks like: Gives explicit, actionable return precautions.*
- [cough_visit · safety_net] SCORE: missed

**invite_questions** — Did the clinician invite final questions before closing?
  *good looks like: Explicitly asks what questions the patient has.*
- [cough_visit · invite_questions] SCORE: missed
