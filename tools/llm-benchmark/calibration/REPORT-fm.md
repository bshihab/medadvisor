# Calibration report — human vs judge (judge-fm)

Judge run(s): apple-foundation-model (system, on-device) (no_think=True)

- decisions compared: 62 (+1 human-na excluded, +0 unscored)
- **binary agreement (met vs not-met): 48.4%  (30/62)**
- exact-status agreement: 40.3%  (25/62)

- **with verifier: 71.0%  (44/62)** — verifier rejected 20 credits: 17 over-credits fixed, 3 correct credits destroyed

  Correct credits destroyed (recall damage):
  - headache_visit · set_tone
  - rash_visit · explain_exam
  - rash_visit · shared_plan

- WARNING: 1 scored decision(s) with no judge output

## Per-criterion

| criterion | n | agree | human met | judge met |
|---|---|---|---|---|
| intro_self | 4 | 1/4 | 1 | 4 |
| set_tone | 4 | 2/4 | 2 | 4 |
| open_questions | 4 | 2/4 | 2 | 4 |
| explore_complaint | 3 | 2/3 | 2 | 3 |
| avoid_interrupting | 4 | 1/4 | 1 | 4 |
| what_else | 4 | 1/4 | 1 | 4 |
| explore_perspective | 4 | 3/4 | 1 | 2 |
| respond_emotion | 4 | 1/4 | 0 | 3 |
| support_respect | 4 | 1/4 | 1 | 4 |
| explain_exam | 3 | 2/3 | 2 | 3 |
| plain_language | 4 | 3/4 | 3 | 4 |
| accurate_info | 4 | 2/4 | 2 | 4 |
| shared_plan | 4 | 2/4 | 2 | 4 |
| check_understanding | 4 | 4/4 | 1 | 1 |
| safety_net | 4 | 2/4 | 2 | 4 |
| invite_questions | 4 | 1/4 | 1 | 4 |

## Disagreements (binary)

### backpain_visit · respond_emotion — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: That's a really understandable worry, especially with your uncle — I'd probably have been googling too.
- judge raw: `RESULT: done
EVIDENCE: "That's a really understandable worry, especially with your uncle — I'd probably have been googling too."
TIP: Validate emotions by acknowledging them and responding thoughtfull`

### backpain_visit · support_respect — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: That's a really understandable worry, especially with your uncle — I'd probably have been googling too.
- judge raw: `RESULT: done
EVIDENCE: "That's a really understandable worry, especially with your uncle — I'd probably have been googling too."
TIP: Ensure to validate patient's feelings and experiences with follow-`

### cough_visit · accurate_info — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles.
- judge raw: `RESULT: done
EVIDENCE: "meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles."
TIP: Ensure to confirm understanding with the patient to reinf`

### cough_visit · avoid_interrupting — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Shirt up, let me listen. Big breaths. In. Out. Again. Right.
- judge raw: `RESULT: done
EVIDENCE: "Shirt up, let me listen. Big breaths. In. Out. Again. Right."
TIP: Ensure to allow the patient to fully express their concerns without interruption.`

### cough_visit · explain_exam — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Right. Chest's clear.
- judge raw: `RESULT: done
EVIDENCE: "Right. Chest's clear."
TIP: Ensure verbal reassurance during physical exams to maintain patient comfort.`

### cough_visit · explore_complaint — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Coughing anything up? Phlegm? What colour?
- judge raw: `RESULT: done
EVIDENCE: "Coughing anything up? Phlegm? What colour?"
TIP: Ensure to ask about severity and associated symptoms during the history-taking process.`

### cough_visit · intro_self — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Yes, come in. Cough, is it?
- judge raw: `RESULT: done
EVIDENCE: "Doctor: Yes, come in. Cough, is it?"
TIP: Ensure to introduce yourself and explain your role at the start of each consultation.`

### cough_visit · invite_questions — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Anything else?
- judge raw: `RESULT: done
EVIDENCE: "Anything else?"
TIP: Ensure to explicitly ask for questions to confirm understanding.`

### cough_visit · open_questions — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Cough, is it?
- judge raw: `RESULT: done
EVIDENCE: "Cough, is it?"
TIP: Ensure questions are broad and allow for patient elaboration.`

### cough_visit · plain_language — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles.
- judge raw: `RESULT: done
EVIDENCE: "meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles."
TIP: Avoid jargon when possible; define terms if necessary.`

### cough_visit · safety_net — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: If it's not gone in another month you can book in again and we'll think about imaging then.
- judge raw: `RESULT: done
EVIDENCE: "If it's not gone in another month you can book in again and we'll think about imaging then."
TIP: Ensure follow-up plan includes imaging if symptoms persist.`

### cough_visit · set_tone — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Big breaths. In. Out. Again. Right.
- judge raw: `RESULT: done
EVIDENCE: "Big breaths. In. Out. Again. Right."
TIP: Ensure pauses between questions to allow the patient to process and respond.`

### cough_visit · shared_plan — human: partial, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: I'll put you on a salbutamol inhaler, two puffs when it's bad. Pharmacy will show you how to use it. Anything else?
- judge raw: `RESULT: done
EVIDENCE: "I'll put you on a salbutamol inhaler, two puffs when it's bad. Pharmacy will show you how to use it. Anything else?"
TIP: Ensure to confirm patient understanding of prescribed `

### cough_visit · support_respect — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles.
- judge raw: `RESULT: done
EVIDENCE: "meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles."
TIP: Ensure to validate patient understanding with follow-up q`

### cough_visit · what_else — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Anything else?
- judge raw: `RESULT: done
EVIDENCE: "Anything else?"
TIP: Ensure to explicitly ask for additional concerns before concluding the consultation.`

### headache_visit · accurate_info — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: I really don't think there's anything scary going on here. Honestly, half my patients this month have headaches, it's going around with everything in the news. Your body's just telling you it's under pressure.
- judge raw: `RESULT: done
EVIDENCE: "I really don't think there's anything scary going on here. Honestly, half my patients this month have headaches, it's going around with everything in the news. Your body's just`

### headache_visit · avoid_interrupting — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Tell me all about it, I'm all ears.
- judge raw: `RESULT: done
EVIDENCE: "Tell me all about it, I'm all ears."
TIP: Avoid interrupting to give the patient space to speak.`

### headache_visit · explore_perspective — human: partial, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: It's not silly at all, it's completely human — everyone goes there at two in the morning. I hear you. And the worry itself feeds the headaches, which is such an unfair little loop, isn't it?
- judge raw: `RESULT: done
EVIDENCE: "It's not silly at all, it's completely human — everyone goes there at two in the morning. I hear you. And the worry itself feeds the headaches, which is such an unfair little l`

### headache_visit · intro_self — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Hello hello, come in! Lovely to see you. Sit down, get comfy. How are you doing?
- judge raw: `RESULT: done
EVIDENCE: "Hello hello, come in! Lovely to see you. Sit down, get comfy. How are you doing?"
TIP: Ensure to introduce yourself and explain your role at the start of each session.`

### headache_visit · invite_questions — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Was there anything else, lovely?
- judge raw: `RESULT: done
EVIDENCE: "Was there anything else, lovely?"
TIP: Ensure to explicitly ask for questions to confirm understanding.`

### headache_visit · respond_emotion — human: partial, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Ohh, redundancies, that's so stressful. No wonder you're not sleeping.
- judge raw: `RESULT: done
EVIDENCE: "Ohh, redundancies, that's so stressful. No wonder you're not sleeping."
TIP: Validate emotions by acknowledging them directly.`

### headache_visit · safety_net — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Anyway — was there anything else, lovely? You've got it. And try not to worry — worry's the real enemy here. Book back in whenever you like if you need to, my door's always open. You take care of yourself, okay?
- judge raw: `RESULT: done
EVIDENCE: "Anyway — was there anything else, lovely? You've got it. And try not to worry — worry's the real enemy here. Book back in whenever you like if you need to, my door's always ope`

### headache_visit · shared_plan — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Be kind to yourself, mainly. Try to ease off the screens where you can, drink some more water, maybe fewer coffees. These things usually sort themselves out once life calms down a bit.
- judge raw: `RESULT: done
EVIDENCE: "Be kind to yourself, mainly. Try to ease off the screens where you can, drink some more water, maybe fewer coffees. These things usually sort themselves out once life calms dow`

### headache_visit · what_else — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Was there anything else, lovely?
- judge raw: `RESULT: done
EVIDENCE: "Was there anything else, lovely?"
TIP: Always confirm understanding and explore further concerns before concluding.`

### rash_visit · avoid_interrupting — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: So this looks very much like eczema — atopic dermatitis is the formal name. Dry, itchy, inflamed patches in the skin creases, the family history, the childhood eczema — it fits together. It hasn't come back because of anything you did wrong; it often resurfaces in adults, especially with stress or in winter.
- judge raw: `RESULT: done
EVIDENCE: "So this looks very much like eczema — atopic dermatitis is the formal name. Dry, itchy, inflamed patches in the skin creases, the family history, the childhood eczema — it fits`

### rash_visit · intro_self — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Hi there, I'm Dr Marsh — sorry, the system's running slow today.
- judge raw: `RESULT: done
EVIDENCE: "Hi there, I'm Dr Marsh — sorry, the system's running slow today."
TIP: Ensure consistent use of name and role introduction throughout consultations.`

### rash_visit · invite_questions — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: So — two-part plan, tell me what you think.
- judge raw: `RESULT: done
EVIDENCE: "So — two-part plan, tell me what you think."
TIP: Always summarize the plan and invite questions to ensure understanding.`

### rash_visit · open_questions — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: So it's about a rash?
- judge raw: `RESULT: done
EVIDENCE: "So it's about a rash?"
TIP: Ensure questions are broad and open-ended to encourage patient storytelling.`

### rash_visit · respond_emotion — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: So this looks very much like eczema — atopic dermatitis is the formal name. Dry, itchy, inflamed patches in the skin creases, the family history, the childhood eczema — it fits together. It hasn't come back because of anything you did wrong; it often resurfaces in adults, especially with stress or in winter.
- judge raw: `RESULT: done
EVIDENCE: "So this looks very much like eczema — atopic dermatitis is the formal name. Dry, itchy, inflamed patches in the skin creases, the family history, the childhood eczema — it fits`

### rash_visit · set_tone — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Ha — well, the doses in these creams are small and we're using it in short bursts, so I'm comfortable, and you can send her to me if she has questions.
- judge raw: `RESULT: done
EVIDENCE: "Ha — well, the doses in these creams are small and we're using it in short bursts, so I'm comfortable, and you can send her to me if she has questions."
TIP: Ensure the clinici`

### rash_visit · support_respect — human: partial, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: So this looks very much like eczema — atopic dermatitis is the formal name. Dry, itchy, inflamed patches in the skin creases, the family history, the childhood eczema — it fits together. It hasn't come back because of anything you did wrong; it often resurfaces in adults, especially with stress or in winter.
- judge raw: `RESULT: done
EVIDENCE: "So this looks very much like eczema — atopic dermatitis is the formal name. Dry, itchy, inflamed patches in the skin creases, the family history, the childhood eczema — it fits`

### rash_visit · what_else — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Any of this run in the family — eczema, asthma, hay fever?
- judge raw: `RESULT: done
EVIDENCE: "Any of this run in the family — eczema, asthma, hay fever?
TIP: Always ask 'is there anything else?' before moving on.`

## Human-na rows (excluded)

- headache_visit · explain_exam (judge said met)
