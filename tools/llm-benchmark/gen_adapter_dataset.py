#!/usr/bin/env python3
"""Synthetic strict-grader training data for the Apple FM adapter (phase 3).

Emits Apple adapter-toolkit chat JSONL — one line per example:
  [{"role": "user", "content": <the app's EXACT scoring prompt>},
   {"role": "assistant", "content": "RESULT: ...\nEVIDENCE: ...\nTIP: ..."}]

Why it looks the way it does:
- The user turn is built by app_scoring.build_prompt — the byte-exact prompt
  the app serves. Train on the serving distribution, nothing else.
- ALL content is authored fresh here. Nothing is reused from
  realistic_cases.json (the decision benchmark) or criterion_snippets.json
  (the snippet benchmark) — both stay uncontaminated as held-out tests.
- The stock model's measured failure is pure leniency (75% over-score, 100%
  recall): it credits anything adjacent. So the dataset is biased toward HARD
  NEGATIVES — doctor lines that superficially resemble a criterion but do not
  satisfy it (generic pleasantries, closed-question barrages, unilateral
  plans, patient-said-it-not-doctor traps, stated intentions). Target mix is
  roughly half "missed", and most misses are hard negatives rather than
  simple absences, because absence is easy and near-miss is what it gets wrong.
- "done" targets carry a VERBATIM quote of the included doctor line, so the
  app's evidence guardrail (verbatim/4-gram/majority-overlap) always agrees
  with the training signal.
- Privacy: every word here is authored fiction. No real patient content.

Split is BY TRANSCRIPT (train/valid), so no transcript's lines leak across.

Usage:
  python gen_adapter_dataset.py                # data/adapter/{train,valid}.jsonl
  python gen_adapter_dataset.py --transcripts 90 --questions-per 7
"""
import argparse, json, random
from pathlib import Path

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
OUT = HERE / "data" / "adapter"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"

# ---------------------------------------------------------------------------
# Authored pools. Per criterion:
#   met:     (doctor line satisfying it, patient reply) — quote-worthy verbatim
#   partial: (doctor line attempting it incompletely, patient reply, tip)
#   near:    (doctor/patient lines RESEMBLING it without satisfying it, tip)
#            — the rubber-stamping killers. Some are patient-said-it traps.
# ---------------------------------------------------------------------------

POOLS = {
"intro_self": {
    "met": [
        ("Good morning, my name's Dr. Whitfield — I'm the GP seeing you today.",
         "Morning, doctor."),
        ("Hello, I'm Dr. Osei, one of the family medicine doctors at this practice.",
         "Nice to meet you."),
        ("Hi there, I'm Dr. Lindqvist, the clinician looking after this clinic today.",
         "Hello, thanks for seeing me."),
    ],
    "partial": [
        ("Hello, I'm Sam — do come in.", "Hi.",
         "Give your full name and your role so the patient knows who they're speaking to."),
    ],
    "near": [
        ("Right, come in and sit down. What are we dealing with today?", "Um, hello.",
         "Open with your name and role before the business of the visit."),
        ("The front desk will have told you who I am. Let's get started.", "Okay…",
         "Introduce yourself directly — don't rely on someone else having done it."),
    ],
},
"set_tone": {
    "met": [
        ("There's no rush at all this morning — the door's closed and this time is yours.",
         "That's a relief, thank you."),
        ("Before we start, are you comfortable? We have a good stretch of time and complete privacy here.",
         "Yes, I'm fine, thank you."),
    ],
    "partial": [
        ("Have a seat — we'll try not to rush this.", "Thanks.",
         "Go further: explicitly attend to comfort or privacy, not just pace."),
    ],
    "near": [
        ("I'm running behind today, so let's keep this brisk.", "Oh — alright.",
         "Avoid signalling time pressure; an unhurried tone helps patients disclose."),
        ("We've got about five minutes, so give me the short version.", "I'll try.",
         "Never open by rationing the patient's time."),
    ],
},
"open_questions": {
    "met": [
        ("Tell me the whole story from the beginning, in your own words.",
         "Well, it started about a month ago after I moved house…"),
        ("What's been happening that brought you in today? Start wherever makes sense to you.",
         "It's this pain, really — it's been creeping up on me."),
    ],
    "partial": [
        ("What brings you in? Is it the knee again?", "Sort of — well, mostly, yes.",
         "Start broad and let the patient frame the problem before suggesting answers."),
    ],
    "near": [
        ("Any fever? Any weight loss? Any night sweats? Bowels okay?", "No… no, all fine, I think.",
         "A barrage of closed questions is not an open invitation — begin with the patient's own account."),
        ("So it's a sore throat, yes or no?", "Yes, but there's more to it—",
         "Yes/no framing shuts the story down; open with 'tell me about it'."),
    ],
},
"explore_complaint": {
    "met": [
        ("When did this first start, how bad does it get at its worst, and have you noticed anything that sets it off or eases it?",
         "About three weeks ago — bad in the evenings, and lying down helps a bit."),
        ("Walk me through it: where exactly do you feel it, how long does each episode last, and is it getting better or worse over time?",
         "Low on the right side, maybe an hour at a time, and honestly it's getting worse."),
    ],
    "partial": [
        ("And when did that start?", "A few weeks back now.",
         "One dimension isn't enough — cover severity, pattern, and what makes it better or worse."),
    ],
    "near": [
        ("Okay, so — stomach pain. We'll get that sorted for you.", "…Right, okay.",
         "Naming the complaint is not exploring it; characterize onset, severity, and triggers."),
        ("I had the exact same thing last winter, dreadful. Anyway.", "Oh, right.",
         "Keep the focus on the patient's symptoms, and actually characterize them."),
    ],
},
"avoid_interrupting": {
    "met": [
        ("Go on — I'm listening, take all the time you need.",
         "Okay… so as I was saying, it's also been affecting my sleep, and my appetite's gone."),
        ("Sorry, you were saying — please finish your thought, it's important.",
         "Thank you — I was going to say it's worse when I'm stressed at work."),
    ],
    "partial": [
        ("—sorry, I cut you off there. Go ahead, finish what you were saying.",
         "It's fine. I was saying the dizziness comes with it.",
         "Better to not interrupt at all — hold questions until the patient finishes."),
    ],
    "near": [
        ("Yes, yes, I've got the picture. Moving on—", "…I hadn't finished, but okay.",
         "Let the patient complete their account; cutting them off loses the history and the rapport."),
        ("Let me stop you there — I need to ask my questions.", "Oh. Alright then.",
         "Don't talk over the patient; there is almost always time to let them finish."),
    ],
},
"what_else": {
    "met": [
        ("Before we go any further — is there anything else at all you wanted to raise today?",
         "Actually, yes, there was one more thing about my sleep."),
        ("We've covered the main thing; what else has been on your mind health-wise?",
         "Nothing else, that's really it."),
    ],
    "partial": [
        ("Anything else?", "Er — no, I suppose not.",
         "A throwaway 'anything else?' invites nothing; pause and ask it like you mean it."),
    ],
    "near": [
        ("Right, so that's everything then. Let's talk about treatment.", "…I guess so.",
         "Don't assume the list is complete — explicitly invite other concerns before moving on."),
        ("We won't have time for anything else today, so let's stick to the cough.", "Okay.",
         "Never foreclose other concerns; a second problem is often the real reason for the visit."),
    ],
},
"explore_perspective": {
    "met": [
        ("What's your own sense of what might be going on — and is there anything particular you were afraid this could be?",
         "Honestly? I keep thinking about my father's heart trouble."),
        ("What were you hoping we'd do about this today — what would a good outcome look like for you?",
         "I mostly just want to know it's nothing serious."),
    ],
    "partial": [
        ("Were you worried about it?", "A bit, yes.",
         "Go beyond yes/no — ask what specifically they think it is, fear, and hope for."),
    ],
    "near": [
        ("Don't go reading the internet about this, it'll only frighten you.",
         "I already did, actually — that's partly why I'm here.",
         "Dismissing the patient's ideas is the opposite of exploring them — ask what they found and what they fear."),
        ("I'm quite worried it might be cancer, my sister had something similar.",
         None,  # patient-said-it trap: patient volunteers fear, clinician never picks it up
         "The patient volunteered a fear — that is an invitation; the clinician must explore it, not the patient."),
    ],
},
"respond_emotion": {
    "met": [
        ("I can hear how frightening the last few weeks have been for you — that's completely understandable, and you did the right thing coming in.",
         "Thank you… it has been a lot."),
        ("You've gone quiet — this sounds like it's been weighing on you heavily. Would you like a moment?",
         "Sorry. Yes. It's just been hard."),
    ],
    "partial": [
        ("Okay, I understand. Now, about the medication—", "…right.",
         "Name the emotion and sit with it briefly before moving to business."),
    ],
    "near": [
        ("Don't worry, it'll all be fine, you'll see.", "…If you say so.",
         "Blanket reassurance skips the emotion; acknowledge it specifically before reassuring."),
        ("Honestly I've been crying most evenings, I feel so overwhelmed.",
         None,  # patient-said-it trap: emotion voiced, never acknowledged
         "The patient disclosed real distress; it must be acknowledged, not passed over."),
    ],
},
"support_respect": {
    "met": [
        ("Whatever we find, you won't be dealing with this on your own — we'll work through it together, step by step.",
         "That means a lot, thank you."),
        ("Thank you for being so open with me — I know none of this is easy to talk about, and I want you to know I take it seriously.",
         "I appreciate that."),
    ],
    "partial": [
        ("We see this a lot, you're not unusual.", "I suppose that's good?",
         "Normalizing helps, but pair it with explicit personal support and concern."),
    ],
    "near": [
        ("Well, if you will keep smoking, what do you expect?", "…I know, but—",
         "Blame erodes trust; express concern without judgement."),
        ("Okay. Take care of yourself, then.", "You too.",
         "A generic sign-off is not support — convey concern and partnership explicitly during the visit."),
    ],
},
"explain_exam": {
    "met": [
        ("I'd like to listen to your chest now — I'll warm the stethoscope first, and just tell me if anything feels uncomfortable.",
         "Okay, that's fine."),
        ("I'm going to press gently on your tummy in a few places to check for tenderness — say the word and I'll stop straight away.",
         "Alright."),
    ],
    "partial": [
        ("I'll examine you now, if that's alright.", "Sure.",
         "Consent is good — also narrate what you're doing as you go and check comfort."),
    ],
    "near": [
        ("Shirt up, please. Breathe in. And out.", "…Okay.",
         "Bare commands aren't an explanation — say what you're doing and why, and check comfort."),
        ("Let me just have a quick look at you.", "Er — at what, exactly?",
         "'A quick look' explains nothing; name the examination and what it involves."),
    ],
},
"plain_language": {
    "met": [
        ("The scan of your back looks reassuring — the discs, the little cushions between the bones, are where they should be, and nothing is pressing on a nerve.",
         "Oh good, that's a relief to hear."),
        ("Your blood pressure is a bit higher than we'd like — think of it as the plumbing running at too high a pressure, which over years wears the pipes.",
         "That makes sense when you put it that way."),
    ],
    "partial": [
        ("It's gastritis — inflammation of the stomach lining, basically an irritated stomach.", "Okay.",
         "Good start defining the term — keep every explanation in everyday words, not just the diagnosis."),
    ],
    "near": [
        ("It's most likely benign paroxysmal positional vertigo, idiopathic, self-limiting, managed conservatively with vestibular rehabilitation.",
         "…I don't really know what any of that means.",
         "Translate every term: brief dizzy spells from the inner ear, harmless, usually settling on their own."),
        ("The radiograph excludes osseous pathology; it's likely musculoskeletal in aetiology.",
         "Right… is that good?",
         "Say it plainly: the X-ray shows no bone damage; it's likely a muscle strain."),
    ],
},
"accurate_info": {
    "met": [
        ("Most sore throats like yours are viral, so antibiotics genuinely won't help — but if the fever lasts beyond three days or swallowing gets harder, that changes the picture and I'd want to see you again.",
         "Okay, that's clear."),
        ("This medication helps most people within two weeks, though it can cause an upset stomach early on — taking it with food usually prevents that.",
         "Good to know, I'll do that."),
    ],
    "partial": [
        ("It's probably nothing serious, but the tablets should help.", "Alright.",
         "Say what it likely is and what the tablets actually do — vague reassurance isn't information."),
    ],
    "near": [
        ("Headaches like this are never anything to worry about — I can promise you that.",
         "Are you sure? It's been every day…",
         "Never promise certainty; give honest likelihoods and the signs that would change the assessment."),
        ("Antibiotics will clear this cold right up.", "Oh — I thought colds were viruses?",
         "Colds are viral; antibiotics don't help them. Information must be correct."),
    ],
},
"shared_plan": {
    "met": [
        ("So there are two reasonable options: physio first and review in six weeks, or a scan straight away. They're both sound — which feels right to you?",
         "I'd rather try the physio first, I think."),
        ("Here's what I'd suggest as our plan — start the inhaler, keep a symptom diary, and meet again in a month. How does that sit with you? Anything you'd change?",
         "That works for me — the diary is a good idea."),
    ],
    "partial": [
        ("The plan is physio and a review in six weeks — okay?", "Okay.",
         "'Okay?' at the end isn't involvement — offer the options and invite a preference."),
    ],
    "near": [
        ("I'll start you on these tablets. Collect them from the pharmacy on your way out.",
         "Oh — right, okay then.",
         "A unilateral instruction isn't a shared plan; lay out options and involve the patient in the choice."),
        ("We should probably discuss a plan at some point soon.", "…Sure.",
         "Intending to plan is not planning — agree concrete next steps in this visit."),
    ],
},
"check_understanding": {
    "met": [
        ("Just so I know I explained it properly — could you tell me back, in your own words, what we've agreed you'll do?",
         "Take the white tablet each morning, keep the diary, and come back in a month."),
        ("Before you go, run me through the plan as you understand it — I want to be sure I haven't muddled anything.",
         "Physio twice a week, painkillers only if I need them, and ring if it gets worse."),
    ],
    "partial": [
        ("Does all of that make sense?", "I think so, yes.",
         "'Does that make sense' invites a polite yes — ask them to repeat the plan back instead."),
    ],
    "near": [
        ("You got all that, yes? Good.", "Er — yes.",
         "That's rhetorical, not a check; use teach-back to confirm real understanding."),
        ("I've written it all down for you, so no need to remember anything.", "Okay, thanks.",
         "A leaflet doesn't confirm understanding — have the patient say the plan back."),
    ],
},
"safety_net": {
    "met": [
        ("If the pain moves to the right lower side, you spike a fever, or you start vomiting, don't wait for this appointment — go to A&E the same day.",
         "Understood — right side, fever, vomiting."),
        ("Watch for three things: blood when you cough, breathlessness at rest, or the fever returning after it's settled. Any of those, ring us that day or call 111 out of hours.",
         "Okay — I'll keep an eye out for those."),
    ],
    "partial": [
        ("If it doesn't settle, come back and see us.", "Alright.",
         "Say exactly WHAT should bring them back, HOW SOON, and WHERE to go."),
    ],
    "near": [
        ("Take care of yourself, then. Bye now.", "Bye, doctor.",
         "A friendly goodbye is not safety-netting — name the red flags and the action to take."),
        ("Try not to worry about it — it'll sort itself out.", "…If you're sure.",
         "Reassurance without red flags leaves the patient with no plan if things worsen."),
    ],
},
"invite_questions": {
    "met": [
        ("Before we finish — what questions do you have for me? Nothing is too small to ask.",
         "Actually, yes — can I still drive while taking these?"),
        ("We've covered a lot; what would you like me to go over again, or explain differently?",
         "Could you explain the diary part once more?"),
    ],
    "partial": [
        ("No questions? Great.", "Um — no. I don't think so.",
         "Phrase it expecting questions — 'what questions do you have?' — and leave a real pause."),
    ],
    "near": [
        ("Right, we're all done here. The nurse will show you out.", "Oh — okay.",
         "Closing without inviting questions leaves doubts unspoken; ask explicitly before ending."),
        ("I've got a full waiting room, so unless it's urgent…", "No, it's fine, never mind.",
         "Never gate questions behind time pressure — invite them genuinely."),
    ],
},
}

# Neutral filler exchanges — history/context lines that satisfy no criterion,
# so transcripts aren't wall-to-wall criterion behavior.
FILLERS = [
    ("And are you on any regular medication at the moment?", "Just the occasional paracetamol."),
    ("Any allergies that you know of?", "Penicillin gives me a rash."),
    ("Is there anything like this in the family?", "My mum had her gallbladder out, that's all I know of."),
    ("And what sort of work do you do?", "I'm on my feet all day — warehouse shifts."),
    ("How's your sleep been through all this?", "Not great, five or six hours if I'm lucky."),
    ("Do you smoke, or drink much?", "Neither, really. A glass of wine at weekends."),
    ("Had you tried anything for it yourself before coming in?", "Some ibuprofen from the chemist, didn't touch it."),
]

OPENINGS = [
    "I've been getting these headaches nearly every day.",
    "It's this cough — it's hung around for weeks now.",
    "I've had a dull pain low in my back that won't shift.",
    "I keep getting dizzy spells out of nowhere.",
    "There's a rash on my arm that's been spreading.",
    "I've been so tired lately it's frightening me.",
    "My stomach's been playing up for about a month.",
    "My knee keeps giving way on the stairs.",
]


def assemble(rng, criteria_ids):
    """Build one transcript: per criterion pick a state, include the matching
    authored lines (shuffled order, filler interleaved), return (flat, truth)
    where truth maps criterion -> (label, evidence_line_or_None, tip)."""
    states = {}
    for cid in criteria_ids:
        r = rng.random()
        # absent 30% / met 30% / hard-negative 28% / partial 12%
        if r < 0.30:
            states[cid] = ("absent", None)
        elif r < 0.60:
            states[cid] = ("met", rng.choice(POOLS[cid]["met"]))
        elif r < 0.88:
            states[cid] = ("near", rng.choice(POOLS[cid]["near"]))
        else:
            states[cid] = ("partial", rng.choice(POOLS[cid]["partial"]))

    turns = [("Patient", rng.choice(OPENINGS))]
    truth = {}
    # Keep consultation order (criteria_ids comes in rubric order).
    for cid in criteria_ids:
        state, item = states[cid]
        if state == "absent":
            truth[cid] = ("missed", None,
                          "This was not attempted at all in the consultation.")
            continue
        if state == "met":
            doc, pat = item
            turns.append(("Doctor", doc))
            if pat:
                turns.append(("Patient", pat))
            truth[cid] = ("done", doc, None)
        elif state == "partial":
            doc, pat, tip = item
            turns.append(("Doctor", doc))
            if pat:
                turns.append(("Patient", pat))
            truth[cid] = ("partial", doc, tip)
        else:  # near-miss hard negative
            line, pat, tip = item
            if pat is None:
                # patient-said-it trap: the LINE is the patient's, unanswered
                turns.append(("Patient", line))
            else:
                turns.append(("Doctor", line))
                turns.append(("Patient", pat))
            truth[cid] = ("missed", None, tip)
        if rng.random() < 0.25:
            d, p = rng.choice(FILLERS)
            turns.append(("Doctor", d))
            turns.append(("Patient", p))

    flat = "\n".join(f"{s}: {t}" for s, t in turns)
    return flat, truth


def target(label, evidence, tip):
    ev = evidence if (label in ("done", "partial") and evidence) else "none"
    tp = tip if (label in ("partial", "missed") and tip) else "none"
    return f"RESULT: {label}\nEVIDENCE: {ev}\nTIP: {tp}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcripts", type=int, default=90)
    ap.add_argument("--questions-per", type=int, default=7,
                    help="criterion questions sampled per transcript")
    ap.add_argument("--valid-frac", type=float, default=0.12)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    criteria = json.loads(RUBRIC.read_text())["criteria"]
    cids = [c["id"] for c in criteria]
    cmap = {c["id"]: c for c in criteria}

    examples_by_transcript = []
    stats = {"done": 0, "partial": 0, "missed": 0, "missed_hard": 0}
    guardrail_disagreements = 0

    for _ in range(args.transcripts):
        flat, truth = assemble(rng, cids)
        # Oversample hard-negative + partial questions: they carry the lesson.
        weights = []
        for cid in cids:
            label, ev, tip = truth[cid]
            if label == "missed" and tip and "not attempted" not in tip:
                weights.append(2.0)   # hard negative — the core lesson
            elif label == "partial":
                weights.append(2.0)
            elif label == "done":
                weights.append(1.5)   # keep recall anchored
            else:
                weights.append(1.0)   # plain absence — easy
        picked, seen = [], set()
        while len(picked) < args.questions_per and len(seen) < len(cids):
            c = rng.choices(cids, weights=weights)[0]
            if c not in seen:
                seen.add(c)
                picked.append(c)

        rows = []
        for cid in picked:
            label, ev, tip = truth[cid]
            user = build_prompt(cmap[cid], flat)
            asst = target(label, ev, tip)
            # Sanity: the app's own parser+guardrail must read the target back
            # as the intended label (e.g. a "done" whose quote fails grounding
            # would train the model to fight the guardrail).
            parsed, _ = parse_criterion(asst, flat)
            want = "met" if label == "done" else label
            if parsed != want:
                guardrail_disagreements += 1
                continue
            stats[label] += 1
            if label == "missed" and tip and "not attempted" not in tip:
                stats["missed_hard"] += 1
            rows.append([{"role": "user", "content": user},
                         {"role": "assistant", "content": asst}])
        examples_by_transcript.append(rows)

    # A handful of degenerate-transcript examples: empty / tiny → missed.
    degenerate = []
    for txt in ("", "Patient: Hello?", "Doctor: Hello.\nPatient: Hi."):
        for cid in rng.sample(cids, 3):
            user = build_prompt(cmap[cid], txt)
            asst = target("missed", None,
                          "The transcript is too short to demonstrate this.")
            degenerate.append([{"role": "user", "content": user},
                               {"role": "assistant", "content": asst}])
            stats["missed"] += 1

    rng.shuffle(examples_by_transcript)
    n_valid_t = max(1, int(len(examples_by_transcript) * args.valid_frac))
    valid = [r for t in examples_by_transcript[:n_valid_t] for r in t]
    train = [r for t in examples_by_transcript[n_valid_t:] for r in t] + degenerate
    rng.shuffle(train)

    OUT.mkdir(parents=True, exist_ok=True)
    for name, rows in (("train", train), ("valid", valid)):
        with open(OUT / f"{name}.jsonl", "w") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    total = sum(stats[k] for k in ("done", "partial", "missed"))
    print(f"train: {len(train)}   valid: {len(valid)}   (split by transcript)")
    print(f"labels: done {stats['done']} ({stats['done']/total:.0%})  "
          f"partial {stats['partial']} ({stats['partial']/total:.0%})  "
          f"missed {stats['missed']} ({stats['missed']/total:.0%}) "
          f"[hard-negative misses: {stats['missed_hard']}]")
    print(f"guardrail disagreements (dropped): {guardrail_disagreements}")
    print(f"wrote {OUT}/train.jsonl, {OUT}/valid.jsonl")


if __name__ == "__main__":
    main()
