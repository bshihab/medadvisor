#!/usr/bin/env python3
"""Rubric-scoring benchmark: how well does an on-device LLM apply the rubric?

Runs one model through the app's exact per-criterion scoring on each labeled
transcript and compares to ground truth. Verbose: prints every criterion result
live so you can watch progress.

Key metrics:
  accuracy      — met/missed correct (binary)
  over-score    — % of MISSED criteria the model wrongly marked met  (the bug we care about)
  recall (met)  — % of MET criteria the model correctly marked met
"""
import argparse, json, time
from pathlib import Path

from mlx_lm import load, generate

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
DATA = HERE / "data"
RESULTS = HERE / "results"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="MLX model id (e.g. mlx-community/Qwen2.5-7B-Instruct-4bit)")
    ap.add_argument("--limit", type=int, default=0, help="only first N cases (0 = all)")
    args = ap.parse_args()

    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    dataset = json.loads((DATA / "scoring.json").read_text())
    if args.limit:
        dataset = dataset[:args.limit]

    print(f"Loading {args.model} …")
    model, tokenizer = load(args.model)

    def run_llm(prompt: str) -> str:
        messages = [{"role": "user", "content": prompt}]
        text = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        return generate(model, tokenizer, prompt=text, max_tokens=180, verbose=False)

    total_calls = sum(len(d["labels"]) for d in dataset)
    print(f"Model: {args.model}\nCases: {len(dataset)}   criterion-calls: {total_calls}\n")

    rows = []
    done = 0
    t0 = time.time()
    for case in dataset:
        for cid, truth in case["labels"].items():
            done += 1
            ti = time.time()
            pred, evidence = parse_criterion(
                run_llm(build_prompt(criteria[cid], case["flat"])), case["flat"])
            pred_met = (pred == "met")
            truth_met = (truth == "met")
            ok = (pred_met == truth_met)
            mark = "OK " if ok else ("OVER" if pred_met else "MISS")
            print(f"  [{done:>3}/{total_calls}] {case['id']} {cid:<18} "
                  f"truth={truth:<6} pred={pred:<7} {mark}  ({time.time()-ti:4.1f}s)")
            rows.append({"case": case["id"], "criterion": cid, "truth": truth,
                         "pred": pred, "correct": ok})

    RESULTS.mkdir(exist_ok=True)
    safe = args.model.replace("/", "__")
    (RESULTS / f"scoring_{safe}.json").write_text(json.dumps(rows, indent=2))
    summarize(args.model, rows, time.time() - t0)


def summarize(model, rows, dt):
    n = len(rows)
    correct = sum(r["correct"] for r in rows)
    missed = [r for r in rows if r["truth"] == "missed"]
    met = [r for r in rows if r["truth"] == "met"]
    over = sum(r["pred"] == "met" for r in missed)
    recall = sum(r["pred"] == "met" for r in met)
    print("\n================ SCORING SUMMARY ================")
    print(f"model:        {model}")
    print(f"accuracy:     {correct/n*100:5.1f}%   ({correct}/{n})")
    print(f"over-score:   {over/len(missed)*100:5.1f}%   ({over}/{len(missed)} MISSED criteria wrongly marked met)  ← lower is better")
    print(f"recall(met):  {recall/len(met)*100:5.1f}%   ({recall}/{len(met)} MET criteria correctly marked met)   ← higher is better")
    print(f"time:         {dt:.0f}s")
    print(f"saved: results/scoring_{model.replace('/', '__')}.json")


if __name__ == "__main__":
    main()
