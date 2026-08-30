#!/usr/bin/env python3
"""Do the app's PROSE jobs survive on Apple FM — and does the grading adapter
wreck them?

The 48-decision benchmark only scores job #3's met/missed verdict. The app also
asks the model for (4) a 2-sentence encounter summary, (5) a 4-5 sentence
insights narrative, (2) a one-word N/A gate, and (1) speaker attribution. None
were ever run on Apple FM.

This matters architecturally: `LLMEngine` selects a backend once, at the engine
level, so an adapter trained only on grading three-liners would also serve the
prose jobs. The TIP-diversity collapse (39 distinct -> 5) predicts it degrades
them. This script runs the same prompts through stock and adapter side by side
so the prediction is measured, not assumed.

Prompts mirror Analysis.swift's summaryPrompt / applicabilityGateSuffix /
speakerAttributionPrompt and InsightsView's narrative prompt.

Usage:
  python bench_fm_prose.py --adapter /path/to/strict_grader.fmadapter
"""
import argparse, json, subprocess, sys
from pathlib import Path

from app_scoring import SCORING_PREFIX
from bench_fm import Runner, load_data

HERE = Path(__file__).parent

# --- job 4: encounter summary (Analysis.swift summaryPrompt) ----------------
SUMMARY = ("A doctor met 11 of 16 criteria in a outpatient clinic consultation. "
           "In 2 sentences, summarize how they did overall and the single most important "
           "thing to improve next time. Plain prose, no lists.")

# --- job 5: insights narrative (InsightsView) -------------------------------
INSIGHTS = """A trainee has recorded 6 consultations, meeting 63 of 96 assessed behaviors overall.
Their met-rate changed by 8 points from their earlier to later sessions in this period.
Things they did well (quotes):
- "I'm Doctor Reyes, one of the doctors in clinic today."
- "Take your time — tell me what's been happening in your own words."
Areas flagged for improvement:
- Give explicit return precautions: what to watch for and when to seek help.
- Ask the patient to say the plan back in their own words.
Write a short, encouraging summary (4-5 sentences): what they consistently do well, whether \
they're improving, and the 1-2 most important things to focus on next. Speak directly using "you"."""

# --- job 2: N/A gate (applicabilityGateSuffix) ------------------------------
GATE_SUFFIX = """

Answer ONE factual question about the transcript above — ignore how well \
anything was done.

Considering only the transcript, did the situation this asks about — "If a physical exam \
occurred, did the clinician explain what they were doing and check comfort?" — actually \
arise in this consultation, so it could be assessed at all?

Reply with ONLY one word: "yes" if it applied to this consultation, or "no" if \
it did not apply."""

# --- job 1: speaker attribution (speakerAttributionPrompt) -----------------
ATTR_UTTERANCES = [
    "Good morning, I'm Doctor Patel, one of the GPs here today.",
    "So, tell me in your own words — what's brought you in today?",
    "I've been getting these headaches, most days now, for about three weeks.",
    "I got a bit scared, my aunt had a brain tumour.",
    "That's a really understandable worry, and I'm glad you told me.",
    "Let me examine you — I'll check your blood pressure and look in your eyes.",
]


def attribution_prompt(utterances):
    numbered = "\n".join(f"{i+1}. {u}" for i, u in enumerate(utterances))
    return ("These are numbered utterances from a two-person doctor–patient consultation, "
            "in chronological order. Label EVERY utterance as D (Doctor) or P (Patient).\n"
            "Decide each one from its CONTENT and clinical role.\n"
            'Output ONLY one line per number in the form "N: D" or "N: P". Nothing else.\n\n'
            f"UTTERANCES:\n{numbered}")


ATTR_TRUTH = ["D", "D", "P", "P", "D", "D"]


def run_jobs(runner, label):
    criteria, cases = load_data()
    transcript = cases[0]["flat"]
    out = {}

    jobs = [
        ("4-summary", SUMMARY, 160),
        ("5-insights", INSIGHTS, 320),
        ("2-na-gate", SCORING_PREFIX.format(transcript=transcript) + GATE_SUFFIX, 24),
        ("1-attribution", attribution_prompt(ATTR_UTTERANCES),
         len(ATTR_UTTERANCES) * 5 + 32),
    ]
    for name, prompt, mt in jobs:
        r = runner.call(f"{label}:{name}", prompt, max_tokens=mt)
        out[name] = r["text"].strip() if r["ok"] else f"<{r['errorKind']}: {r.get('errorDetail','')[:80]}>"
    return out


def score_attribution(text):
    """Parse "N: D" lines and score against ATTR_TRUTH."""
    got = {}
    for line in text.splitlines():
        parts = line.replace(".", ":").split(":")
        if len(parts) >= 2 and parts[0].strip().isdigit():
            n = int(parts[0].strip())
            rest = parts[1].strip().upper()
            if rest[:1] in ("D", "P"):
                got[n] = rest[:1]
    correct = sum(1 for i, t in enumerate(ATTR_TRUTH, 1) if got.get(i) == t)
    return correct, len(ATTR_TRUTH), got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", required=True)
    args = ap.parse_args()

    results = {}
    for label, adapter in (("STOCK", None), ("ADAPTER", args.adapter)):
        print(f"\n>>> running the app's other 4 LLM jobs on {label} …", flush=True)
        runner = Runner(adapter=adapter)
        try:
            results[label] = run_jobs(runner, label)
        finally:
            runner.close()

    for job in ("4-summary", "5-insights", "2-na-gate", "1-attribution"):
        print("\n" + "=" * 74)
        print(f"JOB {job}")
        print("=" * 74)
        for label in ("STOCK", "ADAPTER"):
            text = results[label][job]
            print(f"\n--- {label} ---")
            print(text[:700])
            if job == "1-attribution":
                c, n, _ = score_attribution(text)
                print(f"    [attribution score: {c}/{n} correct]")
            if job == "2-na-gate":
                low = text.lower()
                ok = low.startswith("yes") or low.startswith("no")
                print(f"    [one-word answer: {'YES' if ok else 'NO — verbose/malformed'}]")

    out = HERE / "results" / "prose_jobs_stock_vs_adapter.json"
    out.write_text(json.dumps(results, indent=2))
    print(f"\nsaved -> {out}")


if __name__ == "__main__":
    main()
