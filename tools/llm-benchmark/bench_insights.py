#!/usr/bin/env python3
"""The app's INSIGHTS job: a trends-over-time narrative across many sessions.

This is the one production LLM job no benchmark has ever scored — for any model.
There is no single right answer, so it cannot be graded automatically; the point
here is to put two models' output side by side and READ them.

Prompt is a faithful port of InsightsView.swift:128 (the `You are a supportive
clinical communication coach…` block), including the conditional improvement
line and the 320-token budget.

Four cohorts of 10 sessions each, chosen so the narrative has something
different to get right in every case:
  improving  — clear upward trend, should be recognised and reinforced
  declining  — NEGATIVE trend; the honest test, does it stay "encouraging" to
               the point of misleading, or name the regression?
  plateau    — no movement; generic praise is the failure mode here
  mixed      — strong on rapport, weak on closing; should localise the advice

Usage:
  python bench_insights.py --model mlx-community/Qwen3.5-4B-4bit --no-think
  python bench_insights.py --model mlx-community/Qwen2.5-7B-Instruct-4bit
"""
import argparse, json, time
from pathlib import Path

from mlx_lm import load, generate

HERE = Path(__file__).parent
RESULTS = HERE / "results"

# InsightsView.swift:128 — verbatim shape, including the blank lines.
PROMPT = """You are a supportive clinical communication coach. A doctor completed {n} \
recorded consultations, meeting {met} of {total} assessed behaviors overall.
{improvement}

Things they did well (quotes):
{strengths}

Areas flagged for improvement:
{improvements}

Write a short, encouraging summary (4-5 sentences): what they consistently do well, whether \
they're improving, and the 1-2 most important things to focus on next. Speak directly using "you"."""

# ── PROPOSED REPLACEMENT (candidate for InsightsView.swift) ─────────────────
# Two defects in the shipped prompt, both measured:
#   1. It asks for an "encouraging summary" unconditionally, so on a declining
#      cohort both models bent the facts to comply — the 7B wrote "significant
#      progress … improved by -11 points" to a doctor who regressed.
#   2. It hands the model a SIGNED INTEGER and expects it to infer direction.
#      That is arithmetic, not language; models misread the sign. Here the
#      direction is computed in words by the caller (a two-line Swift change),
#      so the model never has to interpret it.
PROMPT_V2 = """You are a clinical communication coach. A doctor completed {n} \
recorded consultations, meeting {met} of {total} assessed behaviors overall ({pct}%).
{improvement}

Things they did well (quotes):
{strengths}

Areas flagged for improvement:
{improvements}

Write a short summary (4-5 sentences) for the doctor: what they consistently do well, \
how their performance is trending, and the 1-2 most important things to focus on next. \
Speak directly using "you".

Be supportive but ACCURATE. Never describe a decline as progress. If the trend is downward \
or flat, say so plainly and frame it as what to work on next. Base every statement on the \
data above — do not invent strengths or progress that is not shown."""


def trend_phrase(pts):
    """Direction in words, computed by the caller — not left to the model."""
    if pts >= 5:
        return f"Their met-rate improved by {pts} points from their earlier to later sessions."
    if pts <= -5:
        return (f"Their met-rate FELL by {abs(pts)} points from their earlier to later "
                "sessions — performance is going backwards in this period.")
    return (f"Their met-rate was essentially unchanged ({pts:+d} points) from their earlier "
            "to later sessions — no real movement either way.")

IMPROVEMENT = "Their met-rate changed by {pts} points from their earlier to later sessions in this period."

COHORTS = [
    dict(id="improving", n=10, met=112, total=160, pts=14,
         strengths=["Good morning, I'm Dr. Adeyemi, one of the doctors in clinic today.",
                    "Take your time — tell me what's been going on in your own words.",
                    "That sounds like it's been weighing on you. I'm glad you came in."],
         improvements=["Give explicit return precautions: what to watch for and when to seek help.",
                       "Ask the patient to say the plan back in their own words.",
                       "Invite final questions before closing the consultation."]),
    dict(id="declining", n=10, met=79, total=160, pts=-11,
         strengths=["Hello, I'm Dr. Rossi — I'll be looking after you today.",
                    "Is there anything else that's been worrying you?"],
         improvements=["Avoid interrupting; let the patient finish before the next question.",
                       "Translate clinical terms into everyday language.",
                       "Offer options and invite the patient's preference rather than issuing a plan.",
                       "Give explicit return precautions."]),
    dict(id="plateau", n=10, met=96, total=160, pts=1,
         strengths=["I'm Dr. Haddad, one of the clinicians here today.",
                    "What's been happening that brought you in?",
                    "I'll explain as I go, and do say if anything's uncomfortable."],
         improvements=["Ask what the patient thinks is going on and what worries them.",
                       "Check understanding with teach-back before closing."]),
    dict(id="mixed", n=10, met=104, total=160, pts=3,
         strengths=["I can hear how frightening the last few weeks have been.",
                    "You won't be dealing with this on your own — we'll work through it together.",
                    "Please, go on — take your time, there's no rush."],
         improvements=["Name the specific red flags and exactly when to seek help.",
                       "Ask the patient to repeat the plan back.",
                       "Invite questions before you close."]),
]


def build(c, version="v1"):
    if version == "v2":
        return PROMPT_V2.format(
            n=c["n"], met=c["met"], total=c["total"],
            pct=round(c["met"] / c["total"] * 100),
            improvement=trend_phrase(c["pts"]),
            strengths="\n".join(f'- "{s}"' for s in c["strengths"]),
            improvements="\n".join(f"- {s}" for s in c["improvements"]))
    return PROMPT.format(
        n=c["n"], met=c["met"], total=c["total"],
        improvement=IMPROVEMENT.format(pts=c["pts"]),
        strengths="\n".join(f'- "{s}"' for s in c["strengths"]),
        improvements="\n".join(f"- {s}" for s in c["improvements"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--no-think", action="store_true")
    ap.add_argument("--prompt", choices=["v1", "v2"], default="v1",
                    help="v1 = shipped prompt; v2 = accuracy-first candidate")
    args = ap.parse_args()

    print(f"Loading {args.model} …")
    model, tokenizer = load(args.model)

    def run(prompt):
        messages = [{"role": "user", "content": prompt}]
        if args.no_think:
            try:
                text = tokenizer.apply_chat_template(messages, add_generation_prompt=True,
                                                     enable_thinking=False)
            except TypeError:
                text = tokenizer.apply_chat_template(
                    [{"role": "user", "content": prompt + "\n/no_think"}],
                    add_generation_prompt=True)
        else:
            text = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        # Same budget as the app (InsightsView.swift:144)
        return generate(model, tokenizer, prompt=text, max_tokens=320, verbose=False)

    rows = []
    for c in COHORTS:
        t0 = time.time()
        out = run(build(c, args.prompt)).strip()
        rows.append({"cohort": c["id"], "met": c["met"], "total": c["total"],
                     "trend_points": c["pts"], "narrative": out,
                     "seconds": round(time.time() - t0, 1)})
        pct = c["met"] / c["total"] * 100
        print(f"\n{'='*74}\nCOHORT: {c['id']}   {c['met']}/{c['total']} ({pct:.0f}%)   "
              f"trend {c['pts']:+d} pts   [{rows[-1]['seconds']}s]\n{'='*74}")
        print(out)

    RESULTS.mkdir(exist_ok=True)
    safe = args.model.replace("/", "__") + ("__nothink" if args.no_think else "") + f"__{args.prompt}"
    (RESULTS / f"insights_{safe}.json").write_text(json.dumps(rows, indent=2))
    print(f"\nrows -> results/insights_{safe}.json")


if __name__ == "__main__":
    main()
