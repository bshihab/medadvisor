# Deliberate-omission test script

A consultation that clearly demonstrates **13 of 16** criteria and clearly omits
**3**. Record it, run it through both models, and compare against the answer key
at the bottom.

## Why this test and not just reading one analysis

The 4B's measured advantage over the 7B is almost entirely **less over-crediting**
— 33.9% of absent behaviours wrongly credited, down to 8.9%. You cannot see that
by reading a single analysis, because both models write fluent, plausible prose
either way. You only see it when you already know what did *not* happen.

Two of the three omissions carry deliberate **bait** — something that sounds like
the behaviour but does not satisfy the criterion. That is where over-crediting
happens, so it is where the two models should visibly differ.

## How to record it

Read both parts aloud at a natural pace, pausing briefly between speakers. Do not
read the headings or the answer key. Roughly 1 minute of speech.

Speaker labels do not need to be perfect — the app's prompt already assumes they
are sometimes wrong.

---

## The script

**Doctor:** Come in, have a seat — make yourself comfortable. No rush, we've plenty of time. So tell me in your own words, what's brought you in?

**Patient:** These headaches. Nearly every day for a month now, and it's really getting to me.

**Doctor:** Go on — take your time.

**Patient:** Afternoons mostly. Like a tight band round my head. Paracetamol helps a bit. Worse after a long day on the computer.

**Doctor:** How bad do they get at their worst, and is there anything else that makes them better or worse?

**Patient:** Seven out of ten maybe. Dark room helps. Coffee makes it worse.

**Doctor:** Is there anything else you wanted to raise today?

**Patient:** No, just the headaches.

**Doctor:** And what do you think might be going on — anything you've been worried it could be?

**Patient:** Honestly, I've been frightened it's a tumour. My mum had one at about my age. I've been lying awake over it.

**Doctor:** That sounds genuinely frightening, and with your mum's history of course that's where your mind goes. I'm glad you told me — you did the right thing coming in, and we'll work through this together.

**Patient:** Thank you.

**Doctor:** I'd like to examine you now. I'll check your blood pressure, then use a light to look at the back of your eyes — it's bright but it doesn't hurt. Say if anything's uncomfortable and I'll stop.

**Patient:** Okay.

**Doctor:** Blood pressure's normal, and the backs of your eyes look completely healthy. In everyday terms this looks like a tension-type headache — the muscles across your scalp and neck tightening up and staying tight.

**Patient:** So it's not serious?

**Doctor:** Nothing I've found today points that way. I won't promise you certainty, though — if the pattern changes, I'd want to know.

**Patient:** That's a relief.

**Doctor:** Two reasonable options. We start with the simple things — screen breaks, cutting the daily paracetamol, sorting your sleep. Or we arrange a scan for peace of mind. What feels right to you?

**Patient:** The simple things first, I think.

**Doctor:** Good. I've written it all down for you so you don't have to remember any of it.

**Patient:** Thanks.

**Doctor:** Let's put a review in the diary for three weeks.

**Patient:** Okay.

**Doctor:** Before you go — what questions do you have for me?

**Patient:** None, I don't think. Thanks for listening.

---

## Answer key — DO NOT read aloud

### The 3 that are ABSENT

| Criterion | Why it's absent | Bait that may fool a model |
|---|---|---|
| **intro_self** | The clinician never states a name or a role. Not once. | The warm welcome — "come in, have a seat, make yourself comfortable" — reads like a proper greeting, and a careless grader credits the introduction along with it. |
| **check_understanding** | The patient is never asked to say the plan back. | *"I've written all of it down for you so you don't have to remember any of it."* Sounds thorough and caring; it is the opposite of teach-back — it removes the need for the patient to demonstrate understanding. |
| **safety_net** | No red flags, no what-to-watch-for, no when-to-seek-help. | *"Let's put a review in the diary for three weeks."* A routine review is **not** a safety net. A safety net names specific symptoms and says get help the same day. |

### The 13 that are PRESENT

set_tone · open_questions · explore_complaint · avoid_interrupting · what_else ·
explore_perspective · respond_emotion · support_respect · explain_exam ·
plain_language · accurate_info · shared_plan · invite_questions

## What to look for in the results

**Score both models on the 3 absent ones only.** Everything else is noise here.

- **Best case:** the 4B marks all three missed; the 7B credits one or two.
- **What would surprise me:** the 4B marking a present criterion as missed. Its
  one measured regression was recall — on the hand-written set it wrongly failed
  3 of 18 genuinely-demonstrated behaviours, so watch for that too.
- **If both credit all three,** my over-crediting numbers do not transfer to real
  recordings, and the honest conclusion is that the benchmark set is easier than
  reality.

Also worth reading regardless of the verdicts: the **tips** each model writes for
the three misses. A useful tip names what to do differently. A useless one just
restates the rubric back at you.
