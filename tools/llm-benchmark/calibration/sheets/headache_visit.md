# Blind scoring sheet — headache_visit

Score every criterion from the transcript below, BEFORE looking
at any judge output. Replace each `?` with: met / partial / missed / na.
The app treats partial and missed both as not-met; na = criterion
does not apply to this consultation.

## Transcript

```
Doctor: Hello hello, come in! Lovely to see you. Sit down, get comfy. How are you doing?
Patient: I'm alright, thanks. Well — mostly alright. It's these headaches.
Doctor: Oh no, headaches are miserable. Tell me all about it, I'm all ears.
Patient: So it's been about a month? Maybe five weeks. It's like a band across my forehead, usually the afternoons. Some days it's barely there, other days I have to just sit in a dark room after work. I've been taking paracetamol most days.
Doctor: You poor thing, that sounds exhausting. Go on — anything else you've noticed about them?
Patient: Um, screens make it worse I think. And I've been really stressed at work, we're going through redundancies, so I don't know if it's connected. My sleep's been rubbish too.
Doctor: Ohh, redundancies, that's so stressful. No wonder you're not sleeping. How are you holding up in yourself, with all of that going on?
Patient: Honestly, not great. I keep thinking, what if it's something worse though? The headaches I mean. My colleague's sister had a brain tumour and it started with headaches, and I know that's silly but it's two in the morning and you start thinking.
Doctor: It's not silly at all, it's completely human — everyone goes there at two in the morning. I hear you. And the worry itself feeds the headaches, which is such an unfair little loop, isn't it?
Patient: Yeah. Yeah, it really is.
Doctor: Have you been managing to eat okay? Drinking enough water? These things matter more than people think.
Patient: Probably not enough water, no. Lots of coffee.
Doctor: Ah, the classic. Well look, I'm really not worried by what you're describing, okay? I want you to hear that. These have all the hallmarks of the ordinary sort of headache that comes with stress and screens and bad sleep. Nothing you've said rings any alarm bells for me.
Patient: You don't think I need a scan or anything?
Doctor: I really don't think there's anything scary going on here. Honestly, half my patients this month have headaches, it's going around with everything in the news. Your body's just telling you it's under pressure.
Patient: Okay... so what should I do about them?
Doctor: Be kind to yourself, mainly. Try to ease off the screens where you can, drink some more water, maybe fewer coffees. These things usually sort themselves out once life calms down a bit.
Patient: Right. Should I keep taking the paracetamol? Because I read somewhere that taking painkillers all the time can actually cause headaches? Is that—
Doctor: Mm, everything in moderation. You know your body best. Anyway — was there anything else, lovely?
Patient: Um. No, I guess not. So, just... water and less screens, basically?
Doctor: You've got it. And try not to worry — worry's the real enemy here. Book back in whenever you like if you need to, my door's always open. You take care of yourself, okay?
Patient: Okay. Thanks, doctor.
```

## Scores

**intro_self** — Did the clinician introduce themselves and explain their role?
  *good looks like: States name and role and greets the patient.*
- [headache_visit · intro_self] SCORE: met

**set_tone** — Did the clinician set a comfortable, unrushed tone (e.g. acknowledging privacy/comfort)?
  *good looks like: Appears unhurried; attends to the patient's comfort and privacy.*
- [headache_visit · set_tone] SCORE: met

**open_questions** — Did the clinician begin with open-ended questions and let the patient tell their story?
  *good looks like: Starts broad before narrowing; invites the patient to elaborate.*
- [headache_visit · open_questions] SCORE: met

**explore_complaint** — Did the clinician explore the presenting complaint thoroughly (onset, duration, severity, associated symptoms, what's been tried)?
  *good looks like: Characterizes the complaint across its key dimensions.*
- [headache_visit · explore_complaint] SCORE: met

**avoid_interrupting** — Did the clinician avoid interrupting and give the patient space to speak?
  *good looks like: Lets the patient finish; does not cut them off.*
- [headache_visit · avoid_interrupting] SCORE: missed

**what_else** — Did the clinician check for additional concerns ('is there anything else?')?
  *good looks like: Explicitly invites further concerns before moving on.*
- [headache_visit · what_else] SCORE: partial

**explore_perspective** — Did the clinician explore the patient's perspective — their ideas, fears, and expectations?
  *good looks like: Asks what the patient thinks is going on, what worries them, or what they're hoping for.*
- [headache_visit · explore_perspective] SCORE: partial

**respond_emotion** — Did the clinician acknowledge and respond to the patient's emotions?
  *good looks like: Names or validates the emotion; responds rather than rushing past it.*
- [headache_visit · respond_emotion] SCORE: partial

**support_respect** — Did the clinician convey support, concern, and respect throughout?
  *good looks like: Warm, respectful language; conveys that the patient is heard.*
- [headache_visit · support_respect] SCORE: met

**explain_exam** — If a physical exam occurred, did the clinician explain what they were doing and check comfort? (N/A if no exam.)
  *good looks like: Narrates the exam and minimizes surprise/discomfort verbally.*
- [headache_visit · explain_exam] SCORE: na

**plain_language** — Did the clinician explain things in plain language, avoiding jargon?
  *good looks like: Uses everyday words; defines any necessary medical terms.*
- [headache_visit · plain_language] SCORE: met

**accurate_info** — Did the clinician give accurate, appropriate information about the condition and options?
  *good looks like: Information given is correct and relevant; avoids false reassurance or overstated certainty.*
- [headache_visit · accurate_info] SCORE: missed

**shared_plan** — Did the clinician discuss a clear plan and involve the patient in decisions?
  *good looks like: Lays out next steps and invites the patient's preferences.*
- [headache_visit · shared_plan] SCORE: partial

**check_understanding** — Did the clinician check the patient's understanding (e.g. teach-back)?
  *good looks like: Asks the patient to restate the plan in their own words.*
- [headache_visit · check_understanding] SCORE: missed

**safety_net** — Did the clinician safety-net (what to watch for, when and how to seek help)?
  *good looks like: Gives explicit, actionable return precautions.*
- [headache_visit · safety_net] SCORE: missed

**invite_questions** — Did the clinician invite final questions before closing?
  *good looks like: Explicitly asks what questions the patient has.*
- [headache_visit · invite_questions] SCORE: partial
