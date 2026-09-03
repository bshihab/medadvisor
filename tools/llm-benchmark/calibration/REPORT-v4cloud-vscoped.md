# Calibration report — human vs judge (judge-v4cloud-vscoped)

Judge run(s): Qwen/Qwen3.5-4B (bf16 cloud) (no_think=True, adapter=lr5e-5/step120)

- decisions compared: 63 (+1 human-na excluded, +0 unscored)
- **binary agreement (met vs not-met): 74.6%  (47/63)**
- exact-status agreement: 68.3%  (43/63)

- **with verifier: 79.4%  (50/63)** — verifier rejected 3 credits: 3 over-credits fixed, 0 correct credits destroyed


## Per-criterion

| criterion | n | agree | human met | judge met |
|---|---|---|---|---|
| intro_self | 4 | 4/4 | 1 | 1 |
| set_tone | 4 | 3/4 | 2 | 1 |
| open_questions | 4 | 3/4 | 2 | 1 |
| explore_complaint | 4 | 3/4 | 3 | 2 |
| avoid_interrupting | 4 | 3/4 | 1 | 2 |
| what_else | 4 | 2/4 | 1 | 3 |
| explore_perspective | 4 | 3/4 | 1 | 2 |
| respond_emotion | 4 | 2/4 | 0 | 2 |
| support_respect | 4 | 3/4 | 1 | 2 |
| explain_exam | 3 | 2/3 | 2 | 3 |
| plain_language | 4 | 2/4 | 3 | 1 |
| accurate_info | 4 | 3/4 | 2 | 3 |
| shared_plan | 4 | 4/4 | 2 | 2 |
| check_understanding | 4 | 4/4 | 1 | 1 |
| safety_net | 4 | 4/4 | 2 | 2 |
| invite_questions | 4 | 2/4 | 1 | 3 |

## Disagreements (binary)

### backpain_visit · respond_emotion — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: That's a really understandable worry, especially with your uncle — I'd probably have been googling too. Let me examine you and then I'll tell you honestly what I think, alright? I'm going to press along your spine, then check the movement in your back and the strength and reflexes in your legs — it might be a bit uncomfortable but tell me and I'll ease off.
- judge raw: `RESULT: done
EVIDENCE: That's a really understandable worry, especially with your uncle — I'd probably have been googling too. Let me examine you and then I'll tell you honestly what I think, alright?`

### backpain_visit · support_respect — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: That's a really understandable worry, especially with your uncle — I'd probably have been googling too. Let me examine you and then I'll tell you honestly what I think, alright? I'm going to press along your spine, then check the movement in your back and the strength and reflexes in your legs — it might be a bit uncomfortable but tell me and I'll ease off.
- judge raw: `RESULT: done
EVIDENCE: That's a really understandable worry, especially with your uncle — I'd probably have been googling too. Let me examine you and then I'll tell you honestly what I think, alright?`

### cough_visit · accurate_info — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: If it's not gone in another month you can book in again and we'll think about imaging then. I've got a full waiting room, so. Prescription's sent through.
- judge raw: `RESULT: done
EVIDENCE: If it's not gone in another month you can book in again and we'll think about imaging then. I've got a full waiting room, so. Prescription's sent through.
TIP: none`

### cough_visit · explain_exam — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Shirt up, let me listen. Big breaths. In. Out. Again. Right. Chest's clear.
- judge raw: `RESULT: done
EVIDENCE: Shirt up, let me listen. Big breaths. In. Out. Again. Right. Chest's clear.
TIP: none`

### cough_visit · invite_questions — human: missed, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Anything else?
- judge raw: `RESULT: done
EVIDENCE: Anything else?
TIP: none`

### cough_visit · what_else — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Anything else?
- judge raw: `RESULT: done
EVIDENCE: Anything else?
TIP: none`

### headache_visit · avoid_interrupting — human: missed, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Go on — anything else you've noticed about them?
- judge raw: `RESULT: done
EVIDENCE: Go on — anything else you've noticed about them?
TIP: none`

### headache_visit · explore_complaint — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Characterizes the complaint across its key dimensions.`

### headache_visit · explore_perspective — human: partial, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Honestly, not great. I keep thinking, what if it's something worse though? The headaches I mean. My colleague's sister had a brain tumour and it started with headaches, and I know that's silly but it's two in the morning and you start thinking.
- judge raw: `RESULT: done
EVIDENCE: Honestly, not great. I keep thinking, what if it's something worse though? The headaches I mean. My colleague's sister had a brain tumour and it started with headaches, and I kn`

### headache_visit · invite_questions — human: partial, judge: met (judge over-credits) — verifier REJECTED (fixed)
- judge evidence: Anyway — was there anything else, lovely?
- judge raw: `RESULT: done
EVIDENCE: Anyway — was there anything else, lovely?
TIP: none`

### headache_visit · open_questions — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Starts broad before narrowing; invites the patient to elaborate.`

### headache_visit · plain_language — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Uses everyday words; defines any necessary medical terms.`

### headache_visit · respond_emotion — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: I hear you. And the worry itself feeds the headaches, which is such an unfair little loop, isn't it?
- judge raw: `RESULT: done
EVIDENCE: I hear you. And the worry itself feeds the headaches, which is such an unfair little loop, isn't it?
TIP: none`

### headache_visit · set_tone — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Appears unhurried; attends to the patient's comfort and privacy.`

### headache_visit · what_else — human: partial, judge: met (judge over-credits) — verifier confirmed (still wrong)
- judge evidence: Anyway — was there anything else, lovely?
- judge raw: `RESULT: done
EVIDENCE: Anyway — was there anything else, lovely?
TIP: none`

### rash_visit · plain_language — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Uses everyday words; defines any necessary medical terms.`

## Human-na rows (excluded)

- headache_visit · explain_exam (judge said missed)
