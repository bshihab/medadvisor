#!/usr/bin/env python3
"""v4 fine-tuning data — v3's proven machinery, relabeled to Bilal's standard.

v3 (cloud, lr5e-5, step 180) was the first fine-tune to beat stock: +9.6 acc,
-21.4 over-score on the 240 set, surviving Q4_K_M quantisation at 95.8%. Its
diversity fixes (12 complaints x registers x STT mess x mislabelled speakers,
quality-tied length) are kept verbatim — they are why training worked at all.

What v4 changes is the LABELING STANDARD: every delta below implements a rule
from grading_style.md, each traceable to one of Bilal's 91 blind rulings.

  1. intro_self: name-only ("Hi, I'm Dr Marsh") moves partial -> near-miss.
     The standard requires name AND role.                       [rule 6]
  2. PATIENT_SUMMARY trap for check_understanding: patient volunteers a
     summary, clinician says "you've got it" -> missed. Confirming their
     summary is not a check.                                    [rule 3]
  3. MISSED_FIRST_CUE for respond_emotion: an earlier emotional cue passes
     unacknowledged, a later one is validated -> partial.       [rule 4]
  4. Interruption poisons exploration: when the visit contains an active
     interruption, a criterion-complete explore_complaint battery is capped
     at partial.                                                [rule 5]
  5. DEFLECT trap for accurate_info: patient asks a direct question, the
     clinician waves it off -> missed.                          [rule 8]
  6. "Throughout" coupling: in a low-quality (rushed) visit, one warm
     support_respect line earns partial, not done.              [rule 2]

HELD OUT, never trained on: calibration/sheets (Bilal's gold), the 48-case
realistic set (checkpoint screen), the 240-decision set (final eval).

Usage:  python gen_finetune_v4.py --transcripts 200
Output: data/finetune_v4/{train,valid}.jsonl  (mlx-lm chat format)
"""
import argparse, json, random, re
from pathlib import Path

from app_scoring import (build_prompt, build_attribution_prompt, parse_criterion,
                         is_placeholder, SUMMARY_PROMPT)

HERE = Path(__file__).parent
OUT = HERE / "data" / "finetune_v4"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"

COMPLAINTS = [
    dict(sym="headaches", open="I've been getting these headaches nearly every day.",
         detail="They come on in the afternoon and screens make them worse.",
         worry="I keep thinking it might be something in my brain.",
         q="Do you think I need a scan?",
         expl="tension-type headache — the muscles around the head tightening up",
         red="sudden severe pain, vision changes, or waking you from sleep"),
    dict(sym="cough", open="This cough has hung around for about three weeks.",
         detail="It's worse at night and I'm not bringing anything up.",
         worry="My dad had lung trouble, so I've been anxious about it.",
         q="Should I be getting an X-ray or something?",
         expl="a post-viral cough — the airways staying irritated after an infection",
         red="coughing up blood, breathlessness at rest, or a fever coming back"),
    dict(sym="back pain", open="My lower back's been hurting for a fortnight now.",
         detail="It's worse first thing and after I've been sitting a while.",
         worry="I'm scared I've slipped a disc.",
         q="Is it safe for me to keep going to the gym?",
         expl="mechanical back pain — the muscles and joints rather than a nerve",
         red="numbness between the legs, trouble passing urine, or leg weakness"),
    dict(sym="tiredness", open="I'm exhausted all the time and I don't know why.",
         detail="I sleep eight hours and still feel like I haven't.",
         worry="I read it could be something with my thyroid.",
         q="Would a blood test show if something's wrong?",
         expl="fatigue with several contributing factors rather than one cause",
         red="losing weight without trying, night sweats, or new lumps"),
    dict(sym="rash", open="There's a rash on my arm that's been spreading.",
         detail="It itches at night and creams from the chemist haven't touched it.",
         worry="I wondered if it's an allergy to something at work.",
         q="Is it contagious? My kids keep grabbing my arm.",
         expl="an eczema-type reaction — the skin barrier getting irritated",
         red="the rash blistering, a fever with it, or it spreading very fast"),
    dict(sym="dizziness", open="I keep getting dizzy spells out of nowhere.",
         detail="The room spins for a minute or so when I turn over in bed.",
         worry="I'm frightened of having a stroke.",
         q="Can I still drive while this is going on?",
         expl="a common inner-ear cause where crystals shift and confuse balance",
         red="slurred speech, face droop, weakness on one side, or a bad headache"),
    dict(sym="low mood", open="I've been feeling really low for a couple of months.",
         detail="I've stopped seeing friends and I can't concentrate at work.",
         worry="I don't want to be on tablets forever.",
         q="Do the tablets change your personality?",
         expl="depression, which is common and treatable in several ways",
         red="thoughts of harming yourself, or feeling unsafe at home"),
    dict(sym="stomach pain", open="My stomach's been playing up for about a month.",
         detail="It's a gnawing pain, worse when I haven't eaten.",
         worry="A friend had an ulcer and I'm worried it's that.",
         q="Should I stop taking the ibuprofen then?",
         expl="irritation of the stomach lining, often acid-related",
         red="vomiting blood, black tarry stools, or pain that suddenly worsens"),
    dict(sym="knee pain", open="My knee keeps giving way on the stairs.",
         detail="It swells up by the evening if I've been on it all day.",
         worry="I'm worried I'll need a replacement.",
         q="Would a brace help, or is that a gimmick?",
         expl="wear in the joint surface rather than anything torn",
         red="the knee locking, giving way completely, or getting hot and red"),
    dict(sym="chest tightness", open="I get this tightness in my chest when I walk uphill.",
         detail="It settles after a few minutes if I stop.",
         worry="My brother had a heart attack at fifty.",
         q="Is this a heart attack coming, doctor?",
         expl="a pattern that needs proper assessment rather than reassurance today",
         red="chest pain at rest, pain spreading to the arm or jaw, or breathlessness"),
    dict(sym="sore throat", open="I've had a sore throat that won't shift.",
         detail="Swallowing hurts and my neck feels swollen.",
         worry="I think I need antibiotics for it.",
         q="Why won't you just give me the antibiotics?",
         expl="most sore throats being viral, where antibiotics genuinely don't help",
         red="trouble breathing or swallowing your own saliva, or drooling"),
    dict(sym="palpitations", open="My heart's been racing at odd times.",
         detail="It lasts a minute or two and then settles on its own.",
         worry="It happens at night and it frightens me.",
         q="Could this be my heart giving out?",
         expl="extra beats that are common and usually harmless",
         red="fainting, chest pain with it, or it lasting more than a few minutes"),
]

# Per criterion: met / partial / near pools. Sentinels (UPPERCASE) trigger
# multi-turn trap constructions in assemble().
T = {
"intro_self": dict(
  met=["Good morning, I'm Dr. {dr} — I'm the GP you're seeing today.",
       "Hello there, my name's Dr. {dr}, one of the doctors in clinic this morning.",
       "Hi, I'm Dr. {dr}. I'm the registrar covering this clinic today.",
       "Morning — Dr. {dr}, I'll be the doctor looking after you today.",
       "I'm Dr. {dr}, one of the family doctors here. Good to meet you."],
  partial=["I'm one of the doctors covering clinic today — come on in.",
           "You're with the duty doctor this morning. Take a seat."],
  # Bilal rule 6: a bare name — even with the title — is not an introduction.
  near=["I'm Dr. {dr}. So — this {sym}, then.",
        "Hello, I'm {dr}. Come on in.",
        "Morning, Dr. {dr}. Take a seat.",
        "Right, come in, sit yourself down. What's the problem?",
        "Ah, come through, come through — good to see you. What's been going on?",
        "Reception will have said who I am. Let's crack on."]),
"set_tone": dict(
  met=["There's no rush at all — the door's shut and this time is yours.",
       "Before we start, are you comfortable there? We've plenty of time and it's private in here.",
       "Take a seat and get comfortable — nobody's going to interrupt us.",
       "We're in no hurry at all this morning — this time is yours.",
       "We've got a good stretch of time, so please don't feel hurried."],
  partial=["Have a seat — we'll try not to rush.", "Sit down, we've got a few minutes."],
  near=["I'm running about half an hour behind, so let's be quick.",
        "We've got five minutes really, so the short version please.",
        "Computer's playing up again, bear with me. So, quickly — what's the trouble?",
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
       "How severe does it get, what were you doing when it started, and what have you tried for it?"],
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
  # Bilal rule 1: the flung version is a token gesture, partial at best.
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
       "I'll examine the {sym} now and explain as I go — let me know if anything feels off."],
  partial=["I'll examine you now, if that's all right.", "Just going to take a look."],
  near=["Top up for me. Deep breath in. And again.",
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
        "You've definitely got nothing wrong with you.",
        "DEFLECT", "DEFLECT"],   # patient asks a direct question; clinician waves it off
  ),
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
        "That's clear, isn't it.",
        "PATIENT_SUMMARY", "PATIENT_SUMMARY"],   # patient self-summarises; clinician just confirms
  ),
"safety_net": dict(
  met=["If you get {red}, don't wait for this appointment — seek help the same day.",
       "Watch for {red}. Any of those, ring us that day or 111 out of hours.",
       "Come straight back if {red} — that's important.",
       "The things that would worry me are {red}. Those mean same-day help."],
  partial=["If it doesn't settle in a couple of weeks, come back and see us.",
           "Any problems, give us a ring."],
  near=["Take care of yourself then. Bye now.",
        "You can always make another appointment if you feel like it.",
        "Try not to worry about it — it'll sort itself out."]),
"invite_questions": dict(
  met=["Before we finish — what questions do you have for me? Nothing's too small.",
       "What would you like me to go over again?",
       "Anything you want to ask before you go?",
       "What haven't I explained well enough?"],
  partial=["No questions? Good.", "All clear? Right."],
  near=["Right, we're done. The nurse will show you out.",
        "There's a queue building out there, so if we're done…",
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
DEFLECTIONS = ["We'll see how it goes before we start worrying about that.",
               "Let's not get ahead of ourselves, eh?",
               "Try not to think about it too much.",
               "We'll cross that bridge if we come to it."]
BRUSH_PAST = ["Okay. And when exactly did it start?",
              "Right. Any fever with it?",
              "Mm. Let's stick with the symptoms for now."]

DISFLUENCY = ["um, ", "so, ", "right, ", "well, ", "erm, ", ""]


def messify(text, rng, level):
    """Make a line look like STT output rather than a script."""
    if level == 0:
        return text
    if rng.random() < 0.30:
        text = rng.choice(DISFLUENCY) + text[0].lower() + text[1:]
    if rng.random() < 0.18:
        text = text.replace("'", "")
    if rng.random() < 0.12:
        text = text.lower()
    if rng.random() < 0.12:
        text = re.sub(r"[.?!]\s+", " ", text, count=1)
    if rng.random() < 0.10:
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

    if rng.random() < 0.5:
        turns.append(("Patient", messify(c["open"], rng, mess)))
    else:
        turns.append(("Doctor", messify("Come in, take a seat.", rng, mess)))
        turns.append(("Patient", messify(c["open"], rng, mess)))

    # Quality level (v3): drives labels AND length together so length is not
    # a shortcut. ~48% met on average.
    q = rng.uniform(0.12, 0.85)

    # Pre-draw all states so cross-criterion couplings can see the whole visit.
    states = {}
    for cid in cids:
        if rng.random() < q:
            states[cid] = "met"
        else:
            s = rng.random()
            states[cid] = "partial" if s < 0.25 else "near" if s < 0.70 else "absent"

    # Bilal rule 5: an active interruption poisons exploration credit.
    interrupted = states["avoid_interrupting"] == "near"
    cap_explore = interrupted and states["explore_complaint"] == "met"
    # Bilal rule 2: in a rushed visit, one warm line is partial, not done.
    low_q = q < 0.40

    for cid in cids:
        state = states[cid]
        if state == "absent":
            truth[cid] = ("missed", None, absence_tip(rng, cmap[cid]))
            continue

        pool = T[cid][state]
        tpl = rng.choice(pool)

        if tpl == "PATIENT_FEAR":
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
        if tpl == "PATIENT_SUMMARY":
            turns.append(("Patient", messify("So basically I rest it, take the tablets, and come back if it's worse — that it?", rng, mess)))
            turns.append(("Doctor", messify("That's it, you've got it.", rng, mess)))
            truth[cid] = ("missed", None,
                          "Confirming the patient's own summary is not a check — the clinician "
                          "must ask them to tell the plan back, not the other way round.")
            continue
        if tpl == "DEFLECT":
            turns.append(("Patient", messify(c["q"], rng, mess)))
            turns.append(("Doctor", messify(rng.choice(DEFLECTIONS), rng, mess)))
            truth[cid] = ("missed", None,
                          "The patient asked a direct question and it was deflected. Answer it "
                          "with accurate, specific information or say honestly what you don't know.")
            continue

        # Bilal rule 4: a met respond_emotion sometimes arrives AFTER an
        # earlier cue was brushed past — that is partial, not done.
        if cid == "respond_emotion" and state == "met" and rng.random() < 0.35:
            turns.append(("Patient", messify(c["worry"], rng, mess)))
            turns.append(("Doctor", messify(rng.choice(BRUSH_PAST), rng, mess)))
            line = messify(fill(tpl, c, dr), rng, mess)
            turns.append(("Doctor", line))
            truth[cid] = ("partial", line,
                          "The first emotional cue passed unacknowledged; responding to the "
                          "second one is a save, not the behaviour. Catch it the first time.")
            continue

        line = messify(fill(tpl, c, dr), rng, mess)
        turns.append(("Doctor", line))
        if rng.random() < 0.65:
            reply = c["detail"] if rng.random() < 0.35 else rng.choice(PATIENT_REPLIES)
            turns.append(("Patient", messify(reply, rng, mess)))

        if state == "met":
            if cid == "explore_complaint" and cap_explore:
                truth[cid] = ("partial", line,
                              "The questions covered the right ground, but the patient's own "
                              "account was cut short — exploration means letting the story "
                              "finish, not extracting the facts.")
            elif cid == "support_respect" and low_q:
                truth[cid] = ("partial", line,
                              "One warm moment in an otherwise brisk consultation — 'throughout' "
                              "means the whole visit, not a single line.")
            else:
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

    # Mislabelled speakers — the app's prompt says labels "are SOMETIMES WRONG".
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
    ap.add_argument("--transcripts", type=int, default=200)
    ap.add_argument("--grading-per", type=int, default=8)
    ap.add_argument("--valid-frac", type=float, default=0.12)
    ap.add_argument("--seed", type=int, default=29)
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
    print(f"DISTINCT doctor lines: {len(doctor_lines)}")
    print(f"DISTINCT tips: {len(tips)}")
    print(f"guardrail disagreements dropped: {dropped}")
    print(f"wrote {OUT}/train.jsonl, {OUT}/valid.jsonl")


if __name__ == "__main__":
    main()
