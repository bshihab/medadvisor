# Calibration report — human vs judge

Judge run(s): mlx-community/Qwen3.5-4B-4bit (no_think=True)

- decisions compared: 63 (+1 human-na excluded, +0 unscored)
- **binary agreement (met vs not-met): 65.1%  (41/63)**
- exact-status agreement: 60.3%  (38/63)


## Per-criterion

| criterion | n | agree | human met | judge met |
|---|---|---|---|---|
| intro_self | 4 | 3/4 | 1 | 2 |
| set_tone | 4 | 3/4 | 2 | 3 |
| open_questions | 4 | 3/4 | 2 | 3 |
| explore_complaint | 4 | 3/4 | 3 | 4 |
| avoid_interrupting | 4 | 1/4 | 1 | 4 |
| what_else | 4 | 2/4 | 1 | 3 |
| explore_perspective | 4 | 2/4 | 1 | 3 |
| respond_emotion | 4 | 2/4 | 0 | 2 |
| support_respect | 4 | 1/4 | 1 | 4 |
| explain_exam | 3 | 2/3 | 2 | 3 |
| plain_language | 4 | 4/4 | 3 | 3 |
| accurate_info | 4 | 2/4 | 2 | 4 |
| shared_plan | 4 | 2/4 | 2 | 4 |
| check_understanding | 4 | 4/4 | 1 | 1 |
| safety_net | 4 | 4/4 | 2 | 2 |
| invite_questions | 4 | 3/4 | 1 | 2 |

## Disagreements (binary)

### backpain_visit · respond_emotion — human: partial, judge: met (judge over-credits)
- judge evidence: That's a really understandable worry, especially with your uncle — I'd probably have been googling too.
- judge raw: `RESULT: done
EVIDENCE: "That's a really understandable worry, especially with your uncle — I'd probably have been googling too."
TIP: None`

### backpain_visit · support_respect — human: partial, judge: met (judge over-credits)
- judge evidence: That's a really understandable worry, especially with your uncle — I'd probably have been googling too.
- judge raw: `RESULT: done
EVIDENCE: "That's a really understandable worry, especially with your uncle — I'd probably have been googling too."
TIP: none`

### cough_visit · accurate_info — human: missed, judge: met (judge over-credits)
- judge evidence: Three weeks is nothing for a cough, they can go eight weeks after a virus. Airways are irritable after the infection. It settles.
- judge raw: `RESULT: done
EVIDENCE: "Three weeks is nothing for a cough, they can go eight weeks after a virus. Airways are irritable after the infection. It settles."
TIP: none`

### cough_visit · avoid_interrupting — human: missed, judge: met (judge over-credits)
- judge evidence: I'll put you on a salbutamol inhaler, two puffs when it's bad. Pharmacy will show you how to use it. Anything else?
- judge raw: `RESULT: done
EVIDENCE: "I'll put you on a salbutamol inhaler, two puffs when it's bad. Pharmacy will show you how to use it. Anything else?"
TIP: None`

### cough_visit · explain_exam — human: missed, judge: met (judge over-credits)
- judge evidence: Shirt up, let me listen. Big breaths. In. Out. Again. Right. Chest's clear.
- judge raw: `RESULT: done
EVIDENCE: "Shirt up, let me listen. Big breaths. In. Out. Again. Right. Chest's clear."
TIP: None`

### cough_visit · explore_complaint — human: missed, judge: met (judge over-credits)
- judge evidence: It's been going on about three weeks now... A little bit in the mornings... Mostly it's dry though... I quit four years ago... Not really short of breath. Sometimes the coughing fits make my chest sore... I did want to ask about—
- judge raw: `RESULT: done
EVIDENCE: "It's been going on about three weeks now... A little bit in the mornings... Mostly it's dry though... I quit four years ago... Not really short of breath. Sometimes the coughin`

### cough_visit · invite_questions — human: missed, judge: met (judge over-credits)
- judge evidence: Anything else?
- judge raw: `RESULT: done
EVIDENCE: "Anything else?"
TIP: none`

### cough_visit · shared_plan — human: partial, judge: met (judge over-credits)
- judge evidence: I'll put you on a salbutamol inhaler, two puffs when it's bad. Pharmacy will show you how to use it. Anything else?
- judge raw: `RESULT: done
EVIDENCE: "I'll put you on a salbutamol inhaler, two puffs when it's bad. Pharmacy will show you how to use it. Anything else?"
TIP: none`

### cough_visit · support_respect — human: missed, judge: met (judge over-credits)
- judge evidence: I'll put you on a salbutamol inhaler... Pharmacy will show you how to use it.
- judge raw: `RESULT: done
EVIDENCE: "I'll put you on a salbutamol inhaler... Pharmacy will show you how to use it."
TIP: None`

### cough_visit · what_else — human: partial, judge: met (judge over-credits)
- judge evidence: Anything else?
- judge raw: `RESULT: done
EVIDENCE: "Anything else?"
TIP: none`

### headache_visit · accurate_info — human: missed, judge: met (judge over-credits)
- judge evidence: These have all the hallmarks of the ordinary sort of headache that comes with stress and screens and bad sleep. Nothing you've said rings any alarm bells for me.
- judge raw: `RESULT: done
EVIDENCE: "These have all the hallmarks of the ordinary sort of headache that comes with stress and screens and bad sleep. Nothing you've said rings any alarm bells for me."
TIP: none`

### headache_visit · avoid_interrupting — human: missed, judge: met (judge over-credits)
- judge evidence: Go on — anything else you've noticed about them?
- judge raw: `RESULT: done
EVIDENCE: "Go on — anything else you've noticed about them?"
TIP: none`

### headache_visit · explore_perspective — human: partial, judge: met (judge over-credits)
- judge evidence: Honestly, not great. I keep thinking, what if it's something worse though? The headaches I mean. My colleague's sister had a brain tumour and it started with headaches, and I know that's silly but it's two in the morning and you start thinking.
- judge raw: `RESULT: done
EVIDENCE: "Honestly, not great. I keep thinking, what if it's something worse though? The headaches I mean. My colleague's sister had a brain tumour and it started with headaches, and I k`

### headache_visit · respond_emotion — human: partial, judge: met (judge over-credits)
- judge evidence: Honestly, not great. I keep thinking, what if it's something worse though... The headaches I mean. My colleague's sister had a brain tumour... and I know that's silly but it's two in the morning and you start thinking.
- judge raw: `RESULT: done
EVIDENCE: "Honestly, not great. I keep thinking, what if it's something worse though... The headaches I mean. My colleague's sister had a brain tumour... and I know that's silly but it's `

### headache_visit · shared_plan — human: partial, judge: met (judge over-credits)
- judge evidence: Be kind to yourself, mainly. Try to ease off the screens where you can, drink some more water, maybe fewer coffees. These things usually sort themselves out once life calms down a bit.
- judge raw: `RESULT: done
EVIDENCE: "Be kind to yourself, mainly. Try to ease off the screens where you can, drink some more water, maybe fewer coffees. These things usually sort themselves out once life calms dow`

### headache_visit · what_else — human: partial, judge: met (judge over-credits)
- judge evidence: Anyway — was there anything else, lovely?
- judge raw: `RESULT: done
EVIDENCE: "Anyway — was there anything else, lovely?"
TIP: None`

### rash_visit · avoid_interrupting — human: missed, judge: met (judge over-credits)
- judge evidence: Um, I thought maybe the new washing powder?
- judge raw: `RESULT: done
EVIDENCE: "Um, I thought maybe the new washing powder?"
TIP: none`

### rash_visit · explore_perspective — human: partial, judge: met (judge over-credits)
- judge evidence: Some people worry about steroid creams — how do you feel about that?
- judge raw: `RESULT: done
EVIDENCE: "Some people worry about steroid creams — how do you feel about that?"
TIP: none`

### rash_visit · intro_self — human: missed, judge: met (judge over-credits)
- judge evidence: Hi there, I'm Dr Marsh
- judge raw: `RESULT: done
EVIDENCE: Hi there, I'm Dr Marsh
TIP: none`

### rash_visit · open_questions — human: missed, judge: met (judge over-credits)
- judge evidence: So it's about a rash?" and "And you said on and off — does anything set it off that you've noticed?
- judge raw: `RESULT: done
EVIDENCE: "So it's about a rash?" and "And you said on and off — does anything set it off that you've noticed?"
TIP: None`

### rash_visit · set_tone — human: missed, judge: met (judge over-credits)
- judge evidence: Hi there, I'm Dr Marsh — sorry, the system's running slow today. Right.
- judge raw: `RESULT: done
EVIDENCE: "Hi there, I'm Dr Marsh — sorry, the system's running slow today. Right."
TIP: None`

### rash_visit · support_respect — human: partial, judge: met (judge over-credits)
- judge evidence: Sorry — that was me asking, the family history bit.
- judge raw: `RESULT: done
EVIDENCE: "Sorry — that was me asking, the family history bit."
TIP: none`

## Human-na rows (excluded)

- headache_visit · explain_exam (judge said missed)
