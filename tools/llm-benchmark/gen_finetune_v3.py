#!/usr/bin/env python3
"""v3 fine-tuning data — built to fix what actually broke v1 and v2.

Post-mortem of the earlier attempts (all six configurations scored BELOW the
untrained model, 85.4%):

  v1  53% "missed" labels          -> model drifted strict, 50% recall
  v2  rebalanced to 40/23/37       -> COLLAPSED to constant answers instead:
                                      "missed" to everything at 100 iters,
                                      "met" to everything at 200
  both ~150 authored lines total   -> the same sentences recycled across every
                                      transcript, so ~600 examples carried
                                      roughly 16 examples' worth of variety
  both clean, tidy, well-labelled  -> nothing like a real STT transcript

The label balance was NOT the main problem, since fixing it made things worse.
The two unfixed causes were **low diversity** and **prompt repetitiveness**:
every grading example shares a near-identical ~950-token prompt differing only
in the transcript and one QUESTION line, so the cheapest way to reduce loss is
to emit a constant. That is exactly the collapse observed.

What is different here:

1. **Real diversity.** Transcripts are generated from 12 presenting complaints x
   multiple phrasings per criterion x 3 registers (warm / brisk / formal), with
   symptom-specific slots filled in. Two transcripts rarely share a sentence.
2. **Realistic mess.** Disfluencies, run-on punctuation, lowercasing, and
   MISLABELLED SPEAKERS — the app's own prompt says labels "are SOMETIMES
   WRONG", so training on perfectly-labelled text teaches the wrong task.
3. **Length variation.** 6-30 turns, so the model cannot key off position.
4. **Held-out early stopping.** Checkpoints are scored against the HAND-WRITTEN
   cases, not synthetic validation loss — the signal that caught the positional
   shortcut last time. Synthetic val loss looked perfect while the model was
   learning "utterance 1 = Patient".

Still true, and the reason expectations are modest: these labels are authored
opinions, and the stock model already agrees with them ~85% of the time. This
can only help if the authored judgment is right about the remaining 15%. The
director's gold scores would replace that assumption with evidence.

Usage:  python gen_finetune_v3.py --transcripts 160
Output: data/finetune_v3/{train,valid}.jsonl  (mlx-lm chat format)
"""
import argparse, json, random, re
from pathlib import Path

from app_scoring import (build_prompt, build_attribution_prompt, parse_criterion,
                         is_placeholder, SUMMARY_PROMPT)

HERE = Path(__file__).parent
OUT = HERE / "data" / "finetune_v3"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"

# 12 presentations. `sym` fills criterion templates; `open`/`detail`/`worry`
# give the patient a distinct voice per complaint.
COMPLAINTS = [
    dict(sym="headaches", open="I've been getting these headaches nearly every day.",
         detail="They come on in the afternoon and screens make them worse.",
         worry="I keep thinking it might be something in my brain.",
         expl="tension-type headache — the muscles around the head tightening up",
         red="sudden severe pain, vision changes, or waking you from sleep"),
    dict(sym="cough", open="This cough has hung around for about three weeks.",
         detail="It's worse at night and I'm not bringing anything up.",
         worry="My dad had lung trouble, so I've been anxious about it.",
         expl="a post-viral cough — the airways staying irritated after an infection",
         red="coughing up blood, breathlessness at rest, or a fever coming back"),
    dict(sym="back pain", open="My lower back's been hurting for a fortnight now.",
         detail="It's worse first thing and after I've been sitting a while.",
         worry="I'm scared I've slipped a disc.",
         expl="mechanical back pain — the muscles and joints rather than a nerve",
         red="numbness between the legs, trouble passing urine, or leg weakness"),
    dict(sym="tiredness", open="I'm exhausted all the time and I don't know why.",
         detail="I sleep eight hours and still feel like I haven't.",
         worry="I read it could be something with my thyroid.",
         expl="fatigue with several contributing factors rather than one cause",
         red="losing weight without trying, night sweats, or new lumps"),
    dict(sym="rash", open="There's a rash on my arm that's been spreading.",
         detail="It itches at night and creams from the chemist haven't touched it.",
         worry="I wondered if it's an allergy to something at work.",
         expl="an eczema-type reaction — the skin barrier getting irritated",
         red="the rash blistering, a fever with it, or it spreading very fast"),
    dict(sym="dizziness", open="I keep getting dizzy spells out of nowhere.",
         detail="The room spins for a minute or so when I turn over in bed.",
         worry="I'm frightened of having a stroke.",
         expl="a common inner-ear cause where crystals shift and confuse balance",
         red="slurred speech, face droop, weakness on one side, or a bad headache"),
    dict(sym="low mood", open="I've been feeling really low for a couple of months.",
         detail="I've stopped seeing friends and I can't concentrate at work.",
         worry="I don't want to be on tablets forever.",
         expl="depression, which is common and treatable in several ways",
         red="thoughts of harming yourself, or feeling unsafe at home"),
    dict(sym="stomach pain", open="My stomach's been playing up for about a month.",
         detail="It's a gnawing pain, worse when I haven't eaten.",
         worry="A friend had an ulcer and I'm worried it's that.",
         expl="irritation of the stomach lining, often acid-related",
         red="vomiting blood, black tarry stools, or pain that suddenly worsens"),
    dict(sym="knee pain", open="My knee keeps giving way on the stairs.",
         detail="It swells up by the evening if I've been on it all day.",
         worry="I'm worried I'll need a replacement.",
         expl="wear in the joint surface rather than anything torn",
         red="the knee locking, giving way completely, or getting hot and red"),
    dict(sym="chest tightness", open="I get this tightness in my chest when I walk uphill.",
         detail="It settles after a few minutes if I stop.",
         worry="My brother had a heart attack at fifty.",
         expl="a pattern that needs proper assessment rather than reassurance today",
         red="chest pain at rest, pain spreading to the arm or jaw, or breathlessness"),
    dict(sym="sore throat", open="I've had a sore throat that won't shift.",
         detail="Swallowing hurts and my neck feels swollen.",
         worry="I think I need antibiotics for it.",
         expl="most sore throats being viral, where antibiotics genuinely don't help",
         red="trouble breathing or swallowing your own saliva, or drooling"),
    dict(sym="palpitations", open="My heart's been racing at odd times.",
         detail="It lasts a minute or two and then settles on its own.",
         worry="It happens at night and it frightens me.",
         expl="extra beats that are common and usually harmless",
         red="fainting, chest pain with it, or it lasting more than a few minutes"),
]

# Per criterion: templates for each state. {sym} etc. are filled per complaint.
# 4-6 variants each, in different registers, so no phrasing dominates.
T = {
"intro_self": dict(
  met=["Good morning, I'm Dr. {dr} — I'm the GP you're seeing today.",
       "Hello there, my name's Dr. {dr}, one of the doctors in clinic this morning.",
       "Hi, I'm Dr. {dr}. I'm the registrar covering this clinic today.",
       "Morning — Dr. {dr}, I'll be looking after you today.",
       "I'm Dr. {dr}, one of the family doctors here. Good to meet you."],
  partial=["Hello, I'm {dr}. Come on in.", "Hi — {dr}. Take a seat."],
  near=["Right, come in, sit yourself down. What's the problem?",
        "Reception will have said who I am. Let's crack on.",
        "Morning. Right — {sym}, is it?",
        "Come in, come in. So what's going on?"]),
"set_tone": dict(
  met=["There's no rush at all — the door's shut and this time is yours.",
       "Before we start, are you comfortable there? We've plenty of time and it's private in here.",
       "Take a seat and get comfortable — nobody's going to interrupt us.",
       "We've got a good stretch of time, so please don't feel hurried."],
  partial=["Have a seat — we'll try not to rush.", "Sit down, we've got a few minutes."],
  near=["I'm running about half an hour behind, so let's be quick.",
        "We've got five minutes really, so the short version please.",
        "Busy morning — let's get straight to it."]),
"open_questions": dict(
  met=["Tell me the whole story from the start, in your own words.",
       "What's been happening? Start wherever makes sense to you.",
       "I'd rather hear it from you — what's been going on?",
       "Talk me through it from the beginning, take your time."],
  partial=["What brings you in? Is it the {sym} again?",
           "So — {sym}? Tell me a bit."],
  near=["Any fever? Weight loss? Night sweats? Bowels all right?",
        "So it's {sym}, yes or no?",
        "Right — {sym}. How long, roughly? Days or weeks?"]),
"explore_complaint": dict(
  met=["When did the {sym} start, how bad does it get at its worst, and does anything make it better or worse?",
       "Walk me through it — where exactly, how long each time, and is it changing over the weeks?",
       "Tell me about the pattern: when it comes, how long it lasts, and what sets it off.",
       "How severe does it get, what were you doing when it started, and what helps?"],
  partial=["And when did that start?", "How long has the {sym} been going on?"],
  near=["Okay — {sym}. We'll get that sorted for you.",
        "I had the same thing last winter, dreadful. Anyway.",
        "Right, {sym}, noted."]),
"avoid_interrupting": dict(
  met=["Go on — take all the time you need, I'm listening.",
       "Sorry, you were saying — please finish, it matters.",
       "Carry on, I won't interrupt.",
       "No, do go on — I want to hear the whole thing."],
  partial=["—sorry, I cut across you. Go ahead.", "Sorry, finish your point."],
  near=["Yes, yes, I've got the gist. Moving on—",
        "Let me stop you there, I need to ask my questions.",
        "Right, right. Anyway—"]),
"what_else": dict(
  met=["Before we go further — anything else at all you wanted to raise today?",
       "What else has been on your mind health-wise?",
       "Is there something else you came in about as well?",
       "We've covered the {sym} — anything else worrying you?"],
  partial=["Anything else?", "That everything?"],
  near=["Right, so that's everything then. Let's talk treatment.",
        "We won't have time for anything else today.",
        "Good, so just the {sym} then."]),
"explore_perspective": dict(
  met=["What's your own sense of what's going on — and is there something you're afraid it might be?",
       "What were you hoping we'd do today? What would a good outcome look like for you?",
       "Has anything crossed your mind about what's causing it?",
       "What worries you most about the {sym}?"],
  partial=["Were you worried about it?", "Any thoughts on what it might be?"],
  near=["Don't go reading the internet, it'll only frighten you.",
        "I wouldn't worry about what it might be — leave that to me.",
        "PATIENT_FEAR"],   # patient voices the fear; clinician never picks it up
  ),
"respond_emotion": dict(
  met=["I can hear how frightening the last few weeks have been — that's completely understandable.",
       "You've gone quiet — this has clearly been weighing on you. Take a moment.",
       "That sounds genuinely distressing, and I'm glad you came in.",
       "It makes complete sense that you're worried about that."],
  partial=["Okay, I understand. Now, the medication—", "Right, I see. Anyway—"],
  near=["Don't worry, it'll all be fine, you'll see.",
        "There's really nothing to be upset about here.",
        "PATIENT_EMOTION"],
  ),
"support_respect": dict(
  met=["Whatever we find, you won't be dealing with this alone — we'll work through it together.",
       "Thank you for being so open with me; I know that isn't easy.",
       "You did the right thing coming in, and I'll stay involved with this.",
       "I want you to know I'm taking this seriously."],
  partial=["We see this a lot, you're not unusual.", "It's very common, this."],
  near=["Well, if you will carry on smoking, what do you expect?",
        "You've left this rather late, haven't you.",
        "Okay. Take care of yourself then."]),
"explain_exam": dict(
  met=["I'd like to listen to your chest — I'll warm this first, and say if anything's uncomfortable.",
       "I'm going to press gently on your tummy in a few spots; tell me and I'll stop.",
       "Let me check your blood pressure and have a look in your eyes — I'll talk you through it.",
       "I'll examine the {sym} now and explain as I go."],
  partial=["I'll examine you now, if that's all right.", "Just going to take a look."],
  near=["Shirt up. Breathe in. And out.",
        "Let me just have a quick look at you.",
        "Hop on the couch."]),
"plain_language": dict(
  met=["In everyday terms, this is {expl} — nothing dangerous.",
       "Put simply: {expl}. That's what's behind the {sym}.",
       "The short version is {expl}, and it's very common.",
       "Think of it as {expl} — that's all this is."],
  partial=["It's {expl}, basically.", "It's what we'd call {expl}."],
  near=["It's likely idiopathic and self-limiting, managed conservatively.",
        "The differential is broad but nothing acute presents.",
        "Radiologically unremarkable, so likely musculoskeletal in aetiology."]),
"accurate_info": dict(
  met=["Most cases like this settle on their own, though if the {sym} changes character that would change my thinking.",
       "This usually improves within a few weeks; if it doesn't, that's worth another look.",
       "The medication helps most people, though it can upset the stomach early on — food helps.",
       "I can't promise it's nothing, but the pattern you describe is reassuring."],
  partial=["It's probably nothing serious.", "The tablets should sort it."],
  near=["This is never anything to worry about, I can promise you that.",
        "Antibiotics will clear that right up.",
        "You've definitely got nothing wrong with you."]),
"shared_plan": dict(
  met=["Two reasonable options: try the simple things and review in a few weeks, or investigate now. Which feels right to you?",
       "Here's what I'd suggest — and tell me if you'd rather do it differently.",
       "We could start treatment today or wait and see. What would you prefer?",
       "I'd like to agree a plan with you rather than just hand you one."],
  partial=["The plan is physio and a review — okay?", "We'll do the tablets then, yes?"],
  near=["I'll start you on these. Collect them on your way out.",
        "We should probably sort out a plan at some point.",
        "I'll refer you. That's that."]),
"check_understanding": dict(
  met=["Just so I know I've explained it properly — could you tell me back what you'll do?",
       "Run me through the plan as you understand it, so I know I haven't muddled it.",
       "What will you tell your partner we agreed today?",
       "Before you go — in your own words, what's the plan?"],
  partial=["Does that make sense?", "You got all that?"],
  near=["I've written it down so you don't need to remember it.",
        "Right, good. Off you go then.",
        "That's clear, isn't it."]),
"safety_net": dict(
  met=["If you get {red}, don't wait for this appointment — seek help the same day.",
       "Watch for {red}. Any of those, ring us that day or 111 out of hours.",
       "Come straight back if {red} — that's important.",
       "The things that would worry me are {red}. Those mean same-day help."],
  partial=["If it doesn't settle, come back and see us.", "Any problems, give us a ring."],
  near=["Take care of yourself then. Bye now.",
        "Try not to worry about it — it'll sort itself out.",
        "Right, that's us done."]),
"invite_questions": dict(
  met=["Before we finish — what questions do you have for me? Nothing's too small.",
       "What would you like me to go over again?",
       "Anything you want to ask before you go?",
       "What haven't I explained well enough?"],
  partial=["No questions? Good.", "All clear? Right."],
  near=["Right, we're done. The nurse will show you out.",
        "I've a full waiting room, so unless it's urgent…",
        "Good. Next patient's waiting."]),
}

PATIENT_REPLIES = ["Okay.", "Right.", "Yes, thank you.", "Mm, I see.", "That makes sense.",
                   "Okay, thanks doctor.", "Right, I understand.", "Yeah.", "Thank you."]
DRS = ["Whitfield", "Osei", "Lindqvist", "Patel", "Moreau", "Nakamura", "Okafor",
       "Ferreira", "Haddad", "Rossi", "Adeyemi", "Kaur", "Brennan", "Silva"]
FILLER_Q = [("And any allergies?", "Penicillin brings me out in a rash."),
            ("Are you on any regular medication?", "Just paracetamol now and then."),
            ("Anything like this in the family?", "Not that I know of."),
            ("What sort of work do you do?", "I'm on my feet all day."),
            ("How's your sleep been?", "Broken, honestly."),
            ("Do you smoke at all?", "Gave up two years ago.")]

DISFLUENCY = ["um, ", "so, ", "right, ", "well, ", "erm, ", ""]


def messify(text, rng, level):
    """Make a line look like STT output rather than a script."""
    if level == 0:
        return text
    if rng.random() < 0.30:
        text = rng.choice(DISFLUENCY) + text[0].lower() + text[1:]
    if rng.random() < 0.18:                       # dropped apostrophe
        text = text.replace("'", "")
    if rng.random() < 0.12:                       # lost sentence case
        text = text.lower()
    if rng.random() < 0.12:                       # run-on punctuation
        text = re.sub(r"[.?!]\s+", " ", text, count=1)
    if rng.random() < 0.10:                       # doubled word
        w = text.split()
        if len(w) > 3:
            i = rng.randrange(1, len(w) - 1)
            text = " ".join(w[:i] + [w[i]] + w[i:])
    return text


def fill(tpl, c, dr):
    return (tpl.replace("{sym}", c["sym"]).replace("{expl}", c["expl"])
               .replace("{red}", c["red"]).replace("{dr}", dr))


def assemble(rng, cids, cmap):
    c = rng.choice(COMPLAINTS)
    dr = rng.choice(DRS)
    mess = rng.choice([0, 1, 1, 2])          # 25% clean, 75% messy
    turns, truth = [], {}

    # Opener: 50/50 doctor-first vs patient-first (v1's positional shortcut).
    if rng.random() < 0.5:
        turns.append(("Patient", messify(c["open"], rng, mess)))
    else:
        turns.append(("Doctor", messify("Come in, take a seat.", rng, mess)))
        turns.append(("Patient", messify(c["open"], rng, mess)))

    # Each transcript gets a QUALITY level, which does two jobs at once: it makes
    # some consultations genuinely good and others genuinely poor (real rubric
    # data is bimodal, not uniform), and it varies length for free — a rushed
    # consultation is short *because* it misses things, so the model cannot learn
    # "long transcript => met" as a shortcut.
    #
    # Averaged over transcripts this lands near 48% met, matching the eval set's
    # 53/47 split. v1 trained at 47% met and drifted strict; v2 "fixed" the ratio
    # and collapsed to a constant instead, because the ratio was never the cause.
    q = rng.uniform(0.12, 0.85)

    for cid in cids:
        r = rng.random()
        if r < q:
            state = "met"
        else:
            # Of what is left: ~25% partial, ~45% near-miss, ~30% never attempted.
            s = rng.random()
            state = "partial" if s < 0.25 else "near" if s < 0.70 else "absent"
        if state == "absent":
            truth[cid] = ("missed", None, absence_tip(rng, cmap[cid]))
            continue

        pool = T[cid][state if state != "absent" else "near"]
        tpl = rng.choice(pool)

        if tpl == "PATIENT_FEAR":                 # patient-said-it trap
            turns.append(("Patient", messify(c["worry"], rng, mess)))
            truth[cid] = ("missed", None,
                          "The patient raised this themselves and it was never followed up — "
                          "that is an invitation to explore, not a box ticked.")
            continue
        if tpl == "PATIENT_EMOTION":
            turns.append(("Patient", messify("Honestly, I've been really frightened about it.", rng, mess)))
            truth[cid] = ("missed", None,
                          "The patient voiced real distress and it passed unacknowledged. "
                          "Name the emotion before moving to business.")
            continue

        line = messify(fill(tpl, c, dr), rng, mess)
        turns.append(("Doctor", line))
        if rng.random() < 0.65:
            reply = c["detail"] if rng.random() < 0.35 else rng.choice(PATIENT_REPLIES)
            turns.append(("Patient", messify(reply, rng, mess)))

        if state == "met":
            truth[cid] = ("done", line, None)
        elif state == "partial":
            truth[cid] = ("partial", line,
                          f"Attempted but incomplete — {cmap[cid].get('whatGoodLooksLike','go further').rstrip('.')}.")
        else:
            truth[cid] = ("missed", None,
                          f"This looks like it but does not satisfy the criterion. "
                          f"Aim for: {cmap[cid].get('whatGoodLooksLike','the behaviour itself').rstrip('.')}.")

        if rng.random() < 0.22:
            d, p = rng.choice(FILLER_Q)
            turns.append(("Doctor", messify(d, rng, mess)))
            turns.append(("Patient", messify(p, rng, mess)))

    # The app's own prompt says speaker labels "are SOMETIMES WRONG". Training on
    # perfectly-labelled text teaches a task the app never actually faces.
    if rng.random() < 0.35 and len(turns) > 4:
        i = rng.randrange(len(turns))
        s, t = turns[i]
        turns[i] = ("Patient" if s == "Doctor" else "Doctor", t)

    flat = "\n".join(f"{s}: {t}" for s, t in turns)
    return turns, flat, truth


ABSENCE = ["Not attempted at all. Aim for: {good}",
           "This never came up — {good_l}",
           "Missing entirely. What good looks like: {good}",
           "No evidence of this anywhere. Target: {good}",
           "Absent from the consultation. Work on: {good}"]


def absence_tip(rng, criterion):
    good = criterion.get("whatGoodLooksLike") or ""
    if is_placeholder(good):
        good = criterion["prompt"].rstrip("?")
    good = good.rstrip(".")
    return rng.choice(ABSENCE).replace("{good}", good).replace("{good_l}", good[0].lower() + good[1:])


def target(label, ev, tip):
    return (f"RESULT: {label}\n"
            f"EVIDENCE: {ev if (label in ('done','partial') and ev) else 'none'}\n"
            f"TIP: {tip if (label in ('partial','missed') and tip) else 'none'}")


def chat(u, a):
    return {"messages": [{"role": "user", "content": u}, {"role": "assistant", "content": a}]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcripts", type=int, default=160)
    ap.add_argument("--grading-per", type=int, default=6)
    ap.add_argument("--valid-frac", type=float, default=0.12)
    ap.add_argument("--seed", type=int, default=23)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    rub = json.loads(RUBRIC.read_text())
    criteria = rub["criteria"]
    cids = [c["id"] for c in criteria]
    cmap = {c["id"]: c for c in criteria}
    enc = rub.get("encounterType") or "clinical"

    per_t, stats, dropped = [], {k: 0 for k in
        ("grading", "attribution", "summary", "done", "partial", "missed", "hard")}, 0
    doctor_lines, tips = set(), set()

    for _ in range(args.transcripts):
        turns, flat, truth = assemble(rng, cids, cmap)
        for s, t in turns:
            if s == "Doctor":
                doctor_lines.add(t)
        rows = []

        picked = rng.sample(cids, min(args.grading_per, len(cids)))
        for cid in picked:
            lab, ev, tip = truth[cid]
            asst = target(lab, ev, tip)
            parsed, _ = parse_criterion(asst, flat)
            if parsed != ("met" if lab == "done" else lab):
                dropped += 1
                continue
            rows.append(chat(build_prompt(cmap[cid], flat), asst))
            stats["grading"] += 1
            stats[lab if lab != "done" else "done"] += 1
            if tip:
                tips.add(tip)
            if lab == "missed" and tip and not tip.startswith(("Not attempted", "This never",
                                                               "Missing", "No evidence", "Absent")):
                stats["hard"] += 1

        if rng.random() < 0.55 and len(turns) >= 4:
            st = rng.choice([0, 1])
            w = turns[st:len(turns) - rng.choice([0, 0, 1])]
            if len(w) >= 4:
                rows.append(chat(build_attribution_prompt([t for _, t in w]),
                                 "\n".join(f"{i+1}: {'D' if s=='Doctor' else 'P'}"
                                           for i, (s, _) in enumerate(w))))
                stats["attribution"] += 1

        if rng.random() < 0.5:
            met = sum(1 for x in cids if truth[x][0] == "done")
            miss = [x for x in cids if truth[x][0] == "missed"]
            if miss:
                rows.append(chat(
                    SUMMARY_PROMPT.format(met=met, applicable=len(cids), encounter=enc,
                                          missed=", ".join(cmap[m]["prompt"].rstrip("?").lower()
                                                           for m in miss[:4])),
                    f"You demonstrated {met} of {len(cids)} behaviours, and the parts you attempted "
                    f"held together. The single most useful change next time is to address "
                    f"{cmap[rng.choice(miss)]['prompt'].rstrip('?').lower()} — that gap does more "
                    f"to undermine the consultation than the others."))
                stats["summary"] += 1

        per_t.append(rows)

    rng.shuffle(per_t)
    nv = max(1, int(len(per_t) * args.valid_frac))
    valid = [r for t in per_t[:nv] for r in t]
    train = [r for t in per_t[nv:] for r in t]
    rng.shuffle(train)

    OUT.mkdir(parents=True, exist_ok=True)
    for name, rows in (("train", train), ("valid", valid)):
        with open(OUT / f"{name}.jsonl", "w") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    g = stats["grading"]
    print(f"train {len(train)}  valid {len(valid)}")
    print(f"tasks: grading {g}  attribution {stats['attribution']}  summary {stats['summary']}")
    print(f"labels: done {stats['done']/g:.0%}  partial {stats['partial']/g:.0%}  "
          f"missed {stats['missed']/g:.0%}  [hard negatives {stats['hard']}]")
    print(f"DISTINCT doctor lines: {len(doctor_lines)}   (v1/v2 had ~150 total)")
    print(f"DISTINCT tips: {len(tips)}")
    print(f"guardrail disagreements dropped: {dropped}")
    print(f"wrote {OUT}/train.jsonl, {OUT}/valid.jsonl")


if __name__ == "__main__":
    main()
