# Calibration report — human vs judge (judge-v4gguf)

Judge run(s): Qwen3.5-4B Q4_K_M GGUF/llama.cpp (no_think=True, adapter=v4 lr5e-5/step120 (merged))

- decisions compared: 63 (+1 human-na excluded, +0 unscored)
- **binary agreement (met vs not-met): 73.0%  (46/63)**
- exact-status agreement: 65.1%  (41/63)


## Per-criterion

| criterion | n | agree | human met | judge met |
|---|---|---|---|---|
| intro_self | 4 | 4/4 | 1 | 1 |
| set_tone | 4 | 3/4 | 2 | 1 |
| open_questions | 4 | 3/4 | 2 | 1 |
| explore_complaint | 4 | 2/4 | 3 | 1 |
| avoid_interrupting | 4 | 3/4 | 1 | 2 |
| what_else | 4 | 2/4 | 1 | 3 |
| explore_perspective | 4 | 3/4 | 1 | 2 |
| respond_emotion | 4 | 2/4 | 0 | 2 |
| support_respect | 4 | 3/4 | 1 | 2 |
| explain_exam | 3 | 2/3 | 2 | 3 |
| plain_language | 4 | 1/4 | 3 | 0 |
| accurate_info | 4 | 3/4 | 2 | 3 |
| shared_plan | 4 | 4/4 | 2 | 2 |
| check_understanding | 4 | 4/4 | 1 | 1 |
| safety_net | 4 | 4/4 | 2 | 2 |
| invite_questions | 4 | 3/4 | 1 | 2 |

## Disagreements (binary)

### backpain_visit · plain_language — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Uses everyday words; defines any necessary medical terms.`

### backpain_visit · respond_emotion — human: partial, judge: met (judge over-credits)
- judge evidence: That's a really understandable worry, especially with your uncle — I'd probably have been googling too. Let me examine you and then I'll tell you honestly what I think, alright? I'm going to press along your spine, then check the movement in your back and the strength and reflexes in your legs — it might be a bit uncomfortable but tell me and I'll ease off.
- judge raw: `RESULT: done
EVIDENCE: That's a really understandable worry, especially with your uncle — I'd probably have been googling too. Let me examine you and then I'll tell you honestly what I think, alright?`

### backpain_visit · support_respect — human: partial, judge: met (judge over-credits)
- judge evidence: That's a really understandable worry, especially with your uncle — I'd probably have been googling too. Let me examine you and then I'll tell you honestly what I think, alright? I'm going to press along your spine, then check the movement in your back and the strength and reflexes in your legs — it might be a bit uncomfortable but tell me and I'll ease off.
- judge raw: `RESULT: done
EVIDENCE: That's a really understandable worry, especially with your uncle — I'd probably have been googling too. Let me examine you and then I'll tell you honestly what I think, alright?`

### cough_visit · accurate_info — human: missed, judge: met (judge over-credits)
- judge evidence: Meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles.
- judge raw: `RESULT: done
EVIDENCE: Meaning post-viral bronchial hyperreactivity most likely. Airways are irritable after the infection. It settles.
TIP: none`

### cough_visit · explain_exam — human: missed, judge: met (judge over-credits)
- judge evidence: Shirt up, let me listen. Big breaths. In. Out. Again. Right. Chest's clear.
- judge raw: `RESULT: done
EVIDENCE: Shirt up, let me listen. Big breaths. In. Out. Again. Right. Chest's clear.
TIP: none`

### cough_visit · invite_questions — human: missed, judge: met (judge over-credits)
- judge evidence: Anything else?
- judge raw: `RESULT: done
EVIDENCE: Anything else?
TIP: none`

### cough_visit · what_else — human: partial, judge: met (judge over-credits)
- judge evidence: Anything else?
- judge raw: `RESULT: done
EVIDENCE: Anything else?
TIP: none`

### headache_visit · avoid_interrupting — human: missed, judge: met (judge over-credits)
- judge evidence: Go on — anything else you've noticed about them?
- judge raw: `RESULT: done
EVIDENCE: Go on — anything else you've noticed about them?
TIP: none`

### headache_visit · explore_complaint — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Characterizes the complaint across its key dimensions.`

### headache_visit · explore_perspective — human: partial, judge: met (judge over-credits)
- judge evidence: You don't think I need a scan or anything?
- judge raw: `RESULT: done
EVIDENCE: You don't think I need a scan or anything?
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

### headache_visit · respond_emotion — human: partial, judge: met (judge over-credits)
- judge evidence: I hear you. And the worry itself feeds the headaches, which is such an unfair little loop, isn't it?
- judge raw: `RESULT: done
EVIDENCE: I hear you. And the worry itself feeds the headaches, which is such an unfair little loop, isn't it?
TIP: none`

### headache_visit · set_tone — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Appears unhurried; attends to the patient's comfort and privacy.`

### headache_visit · what_else — human: partial, judge: met (judge over-credits)
- judge evidence: Anyway — was there anything else, lovely?
- judge raw: `RESULT: done
EVIDENCE: Anyway — was there anything else, lovely?
TIP: none`

### rash_visit · explore_complaint — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Characterizes the complaint across its key dimensions.`

### rash_visit · plain_language — human: met, judge: missed (judge under-credits)
- judge evidence: (none)
- judge raw: `RESULT: missed
EVIDENCE: none
TIP: This looks like it but does not satisfy the criterion. Aim for: Uses everyday words; defines any necessary medical terms.`

## Human-na rows (excluded)

- headache_visit · explain_exam (judge said missed)
