#!/usr/bin/env python3
"""Realistic-transcript scoring benchmark: runs each model over hand-written,
naturally-flowing full consultations (realistic_cases.json) with hand-labeled
ground truth — a tougher, more real test than the snippet-assembled one.

Same metrics + verbose output as bench_scoring.py.
"""
import argparse, json, time
from pathlib import Path

from mlx_lm import load, generate

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
RESULTS = HERE / "results"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    args = ap.parse_args()

    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    cases = json.loads((HERE / "realistic_cases.json").read_text())

    print(f"Loading {args.model} …")
    model, tokenizer = load(args.model)

    def run_llm(prompt: str) -> str:
        messages = [{"role": "user", "content": prompt}]
        text = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        return generate(model, tokenizer, prompt=text, max_tokens=180, verbose=False)

    total = sum(len(c["labels"]) for c in cases)
    print(f"Model: {args.model}\nRealistic cases: {len(cases)}   criterion-calls: {total}\n")

    rows = []
    done = 0
    for case in cases:
        print(f"--- {case['id']}: {case['note']} ---")
        for cid, truth in case["labels"].items():
            done += 1
            ti = time.time()
            pred, _ = parse_criterion(run_llm(build_prompt(criteria[cid], case["flat"])), case["flat"])
            pred_met, truth_met = (pred == "met"), (truth == "met")
            ok = (pred_met == truth_met)
            mark = "OK " if ok else ("OVER" if pred_met else "MISS")
            print(f"  [{done:>3}/{total}] {case['id'][:12]:<12} {cid:<18} "
                  f"truth={truth:<6} pred={pred:<7} {mark}  ({time.time()-ti:4.1f}s)")
            rows.append({"case": case["id"], "criterion": cid, "truth": truth, "pred": pred, "correct": ok})

    RESULTS.mkdir(exist_ok=True)
    safe = args.model.replace("/", "__")
    (RESULTS / f"realistic_{safe}.json").write_text(json.dumps(rows, indent=2))
    summarize(args.model, rows)


def summarize(model, rows):
    n = len(rows)
    correct = sum(r["correct"] for r in rows)
    missed = [r for r in rows if r["truth"] == "missed"]
    met = [r for r in rows if r["truth"] == "met"]
    over = sum(r["pred"] == "met" for r in missed)
    recall = sum(r["pred"] == "met" for r in met)
    print("\n============ REALISTIC SCORING SUMMARY ============")
    print(f"model:        {model}")
    print(f"accuracy:     {correct/n*100:5.1f}%   ({correct}/{n})")
    print(f"over-score:   {over/len(missed)*100:5.1f}%   ({over}/{len(missed)} MISSED wrongly marked met)  ← lower better")
    print(f"recall(met):  {recall/len(met)*100:5.1f}%   ({recall}/{len(met)} MET correctly marked met)   ← higher better")


if __name__ == "__main__":
    main()
