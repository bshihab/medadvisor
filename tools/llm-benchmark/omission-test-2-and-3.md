# Test transcripts 2 and 3

Two recordings that probe **opposite** failure modes. The first transcript
(headaches, 13 of 16 present) landed in the middle and both models scored 15/16
with one error each in opposite directions — so a second mid-range recording
would tell you little. These two push at the edges instead.

| | Present | Absent | What it tests |
|---|---|---|---|
| **A — rushed** | 3 | 13 | **Over-crediting.** With 13 things absent, a generous grader has 13 chances to invent credit. This is where the 7B's 33.9% over-score rate should show. |
| **B — good** | 15 | 1 | **Under-crediting.** With almost everything present, a strict grader has 15 chances to wrongly fail something. This is where the 4B's recall regression should show. |

B also guards against a lazy grader: exactly one criterion is absent, so a model
that simply says "met" to everything scores 15/16 rather than perfect, and the
one it misses is the tell.

Read both parts aloud. Do not read headings or answer keys. ~1 minute each.

---

# TRANSCRIPT A — the rushed consultation

**Doctor:** Right, come in, sit down. I'm running about half an hour behind so let's be quick. Back pain, is it?

**Patient:** Yes, my lower back. It started about three weeks ago and—

**Doctor:** Three weeks. Any numbness in the legs? Any trouble passing water?

**Patient:** No, nothing like that. It's just—

**Doctor:** Fine. How bad, one to ten?

**Patient:** About a six. It's worse in the morning, and sitting makes it—

**Doctor:** Right. Have you tried anything for it?

**Patient:** Ibuprofen. Helps a little. Look, I'm quite worried — my father had spinal cancer and I keep thinking—

**Doctor:** Let me stop you there, I need to examine you. Shirt up. Bend forward. Does that hurt?

**Patient:** A bit. Sorry, I'm a bit emotional about all this.

**Doctor:** Mm. Straight leg raise is negative, no focal neurology, likely mechanical in aetiology rather than radicular.

**Patient:** Sorry, what does that mean?

**Doctor:** It means it's musculoskeletal. I'll put you on naproxen and refer you to physio. Take it with food.

**Patient:** Okay.

**Doctor:** Do come back the same day if you get numbness between your legs, trouble passing urine, or weakness in either leg — those need looking at urgently.

**Patient:** Right.

**Doctor:** Good. Reception will sort your appointment. Next patient's waiting.

## Answer key A — DO NOT read aloud

**PRESENT — only 3:**

- **explore_complaint** — onset (three weeks), severity (six out of ten), pattern (worse in the morning, sitting), what's been tried (ibuprofen). Rushed, but the dimensions are covered.
- **accurate_info** — the content is correct: mechanical back pain, naproxen with food, physio.
- **safety_net** — genuinely good. Names specific red flags and says same day.

**ABSENT — the other 13:** intro_self · set_tone · open_questions ·
avoid_interrupting · what_else · explore_perspective · respond_emotion ·
support_respect · explain_exam · plain_language · shared_plan ·
check_understanding · invite_questions

**Bait worth watching:**

- **explore_perspective** — the patient volunteers the fear ("my father had spinal cancer") and it is never picked up. A patient raising a worry is an invitation to explore, not a box ticked. Models over-credit this constantly.
- **respond_emotion** — "Sorry, I'm a bit emotional about all this" gets "Mm." Nothing else.
- **plain_language** — "focal neurology", "aetiology", "radicular", then "it means it's musculoskeletal", which is still jargon. A lenient grader may credit the attempt to translate.
- **safety_net is PRESENT here** — the opposite of transcript 1. If a model marks it missed, that is a false negative, not strictness.

---

# TRANSCRIPT B — the good consultation

**Doctor:** Good morning, I'm Dr. Ellis, one of the GPs here. Come in and take a seat.

**Patient:** Thank you.

**Doctor:** There's no rush at all — we've a good twenty minutes and the door's shut. So tell me, in your own words, what's been going on?

**Patient:** I've got this rash on my arms. About six weeks now, and it's driving me mad.

**Doctor:** Go on, tell me more — I won't interrupt.

**Patient:** It itches worst at night. I tried a cream from the chemist, made no difference. It seems worse since I started a new job in a kitchen.

**Doctor:** That's really useful. When exactly did it start, how far has it spread, and is it sore as well as itchy?

**Patient:** Started on the backs of my hands, now up to my elbows. Sore where I've scratched it.

**Doctor:** And what's your own sense of what's causing it? Anything you've been worried about?

**Patient:** I wondered if it's something I'm touching at work. I'm frightened I'll have to give up the job — I've only just started.

**Doctor:** That's a real worry, and I can hear how much the job matters to you. Let's take it seriously and see what we can do — giving it up is not where I'd start.

**Patient:** Thank you, that helps.

**Doctor:** I'd like to look at your arms and hands now. I'll just need you to roll your sleeves up. Tell me if anything I do is uncomfortable and I'll stop.

**Patient:** That's fine.

**Doctor:** Thank you. In plain terms, this looks like contact dermatitis — the skin reacting to something it's touching over and over, and the kitchen fits that well. It isn't an infection and you can't pass it to anyone.

**Patient:** That's a relief.

**Doctor:** It usually settles once we work out what's causing it and cut the contact down, though it can take a few weeks and it may flare again. I can't promise it'll clear completely without something changing at work.

**Patient:** Understood.

**Doctor:** Two options. We start a steroid ointment plus gloves and a barrier cream and review in three weeks, or I refer you for patch testing now to pin down the trigger. What would you prefer?

**Patient:** I'd like to try the ointment and gloves first.

**Doctor:** That's reasonable. Just so I know I've explained it clearly — could you tell me back what you'll do this week?

**Patient:** Steroid ointment on the rash, gloves and barrier cream at work, and come back in three weeks.

**Doctor:** Exactly right. And if it blisters, becomes hot and spreading, or you get a fever, don't wait for that appointment — ring us the same day.

**Patient:** Got it.

**Doctor:** What questions do you have for me before you go?

**Patient:** None, I think you've covered everything.

## Answer key B — DO NOT read aloud

**ABSENT — only 1:**

- **what_else** — the clinician never invites additional concerns. No "is there anything else?", no "anything else on your mind?" The consultation goes deep on the rash and never checks whether something else brought them in.

**PRESENT — the other 15:** intro_self · set_tone · open_questions ·
explore_complaint · avoid_interrupting · explore_perspective · respond_emotion ·
support_respect · explain_exam · plain_language · accurate_info · shared_plan ·
check_understanding · safety_net · invite_questions

**What to watch:**

- **check_understanding is real teach-back here** — the patient restates the plan in their own words. Transcript 1 had bait for this and no teach-back; here it is genuine. A model marking it missed is a false negative.
- **accurate_info** deliberately includes honest hedging ("I can't promise it'll clear completely"). That is what good looks like — not a reason to mark it down.
- **A model that says "met" to all 16** has failed this test, and `what_else` is where you see it.

---

## After recording both

Send me each transcript and I run both models on each:

```
.venv/bin/modal run modal_compare_models.py --transcript-file <path>
```

With transcript 1 that makes three recordings spanning poor, mixed and good —
enough to say whether the 4B's measured advantage is real on your own voice, or
whether the benchmark set was simply easier than reality.
