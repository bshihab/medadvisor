#!/usr/bin/env python3
"""Multi-task fine-tuning data for OUR OWN small model (mlx-lm LoRA format).

Different goal from gen_adapter_dataset.py (which targeted Apple's toolkit and
graded only). This trains a model WE own, on ALL the jobs the app actually asks
for, so it can ship as a plain GGUF with no toolkit, entitlement, or version
pinning — and so it does not over-specialize on one task.

Three lessons from the Apple adapter run are designed in:

1. **Diverse tips.** That run reused ONE canned string for every plain-absence
   example (~30% of the data) and the model learned to parrot it: 29 tips, only
   5 distinct, versus 39/39 for the untuned model. Verdict accuracy improved
   while the coaching text — the thing a trainee actually reads — collapsed.
   Here every absence tip is generated from the criterion's own
   `whatGoodLooksLike` through several templates, so tips stay specific and
   varied per criterion.
2. **Multi-task.** Grading (16 calls/encounter) plus speaker attribution and the
   encounter summary (1 each), weighted roughly toward the serving mix. A
   grading-only diet is what caused the over-specialization above.
3. **Hard negatives.** The measured failure of small models here is leniency —
   stock Apple FM credited 75% of absent behaviors, MedGemma-4B 53%. Doctor
   lines that superficially resemble a criterion without satisfying it are the
   core lesson; plain absence is easy.

Prompts come from app_scoring (the port of Analysis.swift), so training matches
the serving distribution byte for byte. NOTE the summary task trains on
`SUMMARY_PROMPT`, a proposed fix that names the missed criteria — the shipped
prompt passes only counts and cannot produce specific advice. That app change
must ship with this model.

Privacy: every word is authored fiction. No patient content, ever.

Output: mlx-lm chat format, one JSON object per line, split BY TRANSCRIPT.
  data/finetune/{train,valid}.jsonl

Usage:
  python gen_finetune_dataset.py                       # ~700 examples
  python gen_finetune_dataset.py --transcripts 120
"""
import argparse, json, random
from pathlib import Path

from app_scoring import (build_prompt, build_attribution_prompt, parse_criterion,
                         is_placeholder, SUMMARY_PROMPT)
from gen_adapter_dataset import POOLS, FILLERS, OPENINGS

HERE = Path(__file__).parent
OUT = HERE / "data" / "finetune"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"

# Absence tips, generated per criterion from the rubric so they are specific and
# varied instead of one repeated string. {good} is the criterion's own
# whatGoodLooksLike; {ask} is a lowercased fragment of its prompt.
ABSENCE_TIP_TEMPLATES = [
    "Not attempted at all in this consultation. Aim for: {good}",
    "This never came up. What good looks like: {good}",
    "Missing entirely — there was no attempt to {ask}",
    "No evidence of this anywhere in the consultation. Target: {good}",
    "Absent. Work on this next time: {good}",
]

# Summary targets: specific (they name a real missed criterion), varied in
# phrasing, always exactly two sentences.
SUMMARY_TEMPLATES = [
    "You covered {met} of {applicable} criteria, and the structure of the "
    "consultation held together well. The single most valuable change next time "
    "is {focus} — that one gap does more to undermine the patient's confidence "
    "than anything else here.",
    "This was a reasonable consultation overall, with {met} of {applicable} "
    "behaviors demonstrated. Prioritise {focus} next time; it is the gap most "
    "likely to leave the patient unsure of what happens next.",
    "You met {met} of {applicable} criteria, showing solid command of the parts "
    "you did attempt. Focus your next consultation on {focus}, which matters "
    "more for patient safety and trust than the remaining gaps.",
    "With {met} of {applicable} criteria met, the foundations are there. The one "
    "thing to change is {focus} — build that in deliberately rather than hoping "
    "it comes up naturally.",
]

# Short human phrasings of each criterion, for the summary's "focus" slot.
FOCUS = {
    "intro_self": "introducing yourself by name and role",
    "set_tone": "setting an unhurried, comfortable tone at the start",
    "open_questions": "opening with a genuinely open question before narrowing",
    "explore_complaint": "characterising the complaint across onset, severity and triggers",
    "avoid_interrupting": "letting the patient finish before you ask your next question",
    "what_else": "explicitly asking whether anything else was on their mind",
    "explore_perspective": "asking what the patient thinks is happening and what worries them",
    "respond_emotion": "naming and acknowledging the emotion before moving on",
    "support_respect": "saying explicitly that you will work through this together",
    "explain_exam": "narrating the examination and checking comfort as you go",
    "plain_language": "translating every clinical term into everyday words",
    "accurate_info": "giving honest likelihoods instead of blanket reassurance",
    "shared_plan": "offering the options and inviting the patient's preference",
    "check_understanding": "asking the patient to say the plan back in their own words",
    "safety_net": "naming the specific red flags and exactly when to seek help",
    "invite_questions": "inviting final questions before you close",
}


def absence_tip(rng, criterion):
    good = criterion.get("whatGoodLooksLike") or ""
    if is_placeholder(good):
        good = ""
    ask = criterion["prompt"].rstrip("?").lower()
    for prefix in ("did the clinician ", "if a physical exam occurred, did the clinician "):
        if ask.startswith(prefix):
            ask = ask[len(prefix):]
    tpl = rng.choice(ABSENCE_TIP_TEMPLATES)
    if not good:                      # fall back to the question itself
        tpl = "Missing entirely — there was no attempt to {ask}"
    return tpl.format(good=good.rstrip("."), ask=ask)


def assemble(rng, criteria_ids, cmap):
    """One synthetic transcript. Returns (turns, flat, truth) where turns is the
    ordered [(speaker, text)] list (needed for the attribution task)."""
    # FIX 1 (label balance). The first version was 53% missed / 32% done, and
    # training progressively absorbed that prior: by 500 iters the model marked
    # almost everything missed (0% over-score but 50% recall). Rebalanced to
    # ~40% done / 40% missed / 20% partial so the target distribution itself is
    # not pulling the model toward strictness. Hard negatives ("near") stay the
    # bulk of the missed mass — they are the actual lesson; plain absence is easy.
    states = {}
    for cid in criteria_ids:
        r = rng.random()
        if r < 0.15:
            states[cid] = ("absent", None)              # 15% easy absence
        elif r < 0.55:
            states[cid] = ("met", rng.choice(POOLS[cid]["met"]))       # 40% done
        elif r < 0.80:
            states[cid] = ("near", rng.choice(POOLS[cid]["near"]))     # 25% hard neg
        else:
            states[cid] = ("partial", rng.choice(POOLS[cid]["partial"]))  # 20%

    turns = [("Patient", rng.choice(OPENINGS))]
    truth = {}
    for cid in criteria_ids:
        state, item = states[cid]
        if state == "absent":
            truth[cid] = ("missed", None, absence_tip(rng, cmap[cid]))
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
        else:
            line, pat, tip = item
            if pat is None:                      # patient-said-it trap
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
    return turns, flat, truth


def verdict_target(label, evidence, tip):
    ev = evidence if (label in ("done", "partial") and evidence) else "none"
    tp = tip if (label in ("partial", "missed") and tip) else "none"
    return f"RESULT: {label}\nEVIDENCE: {ev}\nTIP: {tp}"


def chat(user, assistant):
    return {"messages": [{"role": "user", "content": user},
                         {"role": "assistant", "content": assistant}]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcripts", type=int, default=90)
    ap.add_argument("--grading-per", type=int, default=7)
    ap.add_argument("--valid-frac", type=float, default=0.12)
    ap.add_argument("--seed", type=int, default=17)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    criteria = json.loads(RUBRIC.read_text())["criteria"]
    cids = [c["id"] for c in criteria]
    cmap = {c["id"]: c for c in criteria}
    encounter = json.loads(RUBRIC.read_text()).get("encounterType") or "clinical"

    per_transcript, stats = [], {"grading": 0, "attribution": 0, "summary": 0,
                                 "done": 0, "partial": 0, "missed": 0, "hard_neg": 0,
                                 "attr_first_D": 0, "attr_first_P": 0}
    dropped = 0
    tips_seen = set()

    for _ in range(args.transcripts):
        turns, flat, truth = assemble(rng, cids, cmap)
        rows = []

        # --- task 1: grading (the bulk, matching 16 calls/encounter) ---------
        weights = []
        for cid in cids:
            label, ev, tip = truth[cid]
            hard = label == "missed" and tip and not tip.startswith(
                ("Not attempted", "This never came up", "Missing entirely",
                 "No evidence", "Absent"))
            weights.append(2.0 if hard or label == "partial" else
                           1.5 if label == "done" else 1.0)
        picked, seen = [], set()
        while len(picked) < args.grading_per and len(seen) < len(cids):
            c = rng.choices(cids, weights=weights)[0]
            if c not in seen:
                seen.add(c); picked.append(c)

        for cid in picked:
            label, ev, tip = truth[cid]
            asst = verdict_target(label, ev, tip)
            # The app's own parser+guardrail must read the target back as the
            # intended label, or we would train the model to fight the parser.
            parsed, _ = parse_criterion(asst, flat)
            if parsed != ("met" if label == "done" else label):
                dropped += 1
                continue
            rows.append(chat(build_prompt(cmap[cid], flat), asst))
            stats["grading"] += 1
            stats[label] += 1
            if tip:
                tips_seen.add(tip)
            if label == "missed" and tip and not tip.startswith(
                    ("Not attempted", "This never came up", "Missing entirely",
                     "No evidence", "Absent")):
                stats["hard_neg"] += 1

        # --- task 2: speaker attribution (1 per encounter) ------------------
        # FIX 2 (positional bias). Every transcript here opens with a Patient
        # line, so v1 taught the model "utterance 1 = Patient, then alternate".
        # It scored 100% on synthetic tests (all patient-first) and 30% role /
        # 96.8% separation on real consultations (all doctor-first) — a clean
        # systematic inversion: it had learned position, not content.
        # Randomising the slice start makes the opener 50/50 without touching
        # any label, since labels are derived from the turns actually shown.
        if rng.random() < 0.7:
            start = rng.choice([0, 1])
            end = len(turns) - rng.choice([0, 0, 1])      # occasionally trim the tail
            window = turns[start:end]
            if len(window) >= 4:
                utts = [t for _, t in window]
                labels = "\n".join(f"{i+1}: {'D' if s == 'Doctor' else 'P'}"
                                   for i, (s, _) in enumerate(window))
                rows.append(chat(build_attribution_prompt(utts), labels))
                stats["attribution"] += 1
                stats["attr_first_" + ("D" if window[0][0] == "Doctor" else "P")] += 1

        # --- task 3: encounter summary (1 per encounter) --------------------
        if rng.random() < 0.7:
            met = sum(1 for cid in cids if truth[cid][0] == "done")
            missed_ids = [cid for cid in cids if truth[cid][0] == "missed"]
            if missed_ids:
                focus_id = rng.choice(missed_ids)
                user = SUMMARY_PROMPT.format(
                    met=met, applicable=len(cids), encounter=encounter,
                    missed=", ".join(FOCUS[c] for c in missed_ids[:5]))
                asst = rng.choice(SUMMARY_TEMPLATES).format(
                    met=met, applicable=len(cids), focus=FOCUS[focus_id])
                rows.append(chat(user, asst))
                stats["summary"] += 1

        per_transcript.append(rows)

    rng.shuffle(per_transcript)
    n_valid = max(1, int(len(per_transcript) * args.valid_frac))
    valid = [r for t in per_transcript[:n_valid] for r in t]
    train = [r for t in per_transcript[n_valid:] for r in t]
    rng.shuffle(train)

    OUT.mkdir(parents=True, exist_ok=True)
    for name, rows in (("train", train), ("valid", valid)):
        with open(OUT / f"{name}.jsonl", "w") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    g = stats["grading"]
    print(f"train {len(train)}  valid {len(valid)}   (split by transcript)")
    print(f"tasks: grading {g}  attribution {stats['attribution']}  summary {stats['summary']}")
    print(f"grading labels: done {stats['done']} ({stats['done']/g:.0%})  "
          f"partial {stats['partial']} ({stats['partial']/g:.0%})  "
          f"missed {stats['missed']} ({stats['missed']/g:.0%})  "
          f"[hard negatives {stats['hard_neg']}]")
    print(f"attribution openers: Doctor-first {stats['attr_first_D']}, "
          f"Patient-first {stats['attr_first_P']}  (v1 was 100% Patient-first — the bug)")
    print(f"DISTINCT TIP STRINGS: {len(tips_seen)}  "
          f"(the Apple run shipped ~150 authored + 1 reused; 5 survived in output)")
    print(f"guardrail disagreements dropped: {dropped}")
    print(f"wrote {OUT}/train.jsonl, {OUT}/valid.jsonl")


if __name__ == "__main__":
    main()
