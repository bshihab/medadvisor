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
import argparse, json, os, time
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
    ap.add_argument("--no-think", action="store_true",
                    help="disable reasoning mode (Qwen3/3.5). Without this they emit a long "
                         "'Thinking Process:' block and never reach an answer inside the "
                         "app's token budget — measured: 1 of 21 utterances labeled.")
    ap.add_argument("--adapter-path", help="LoRA adapter directory to load on top of --model")
    ap.add_argument("--realistic", action="store_true",
                    help="score the 48-decision HAND-WRITTEN cases instead of the 240 "
                         "snippet set. Cheap enough to screen every training checkpoint, "
                         "and it is authored separately from the fine-tuning data — "
                         "synthetic validation loss looked perfect while a previous "
                         "adapter was quietly learning 'utterance 1 = Patient'.")
    args = ap.parse_args()

    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    src = (HERE / "realistic_cases.json") if args.realistic else (DATA / "scoring.json")
    dataset = json.loads(src.read_text())
    if args.limit:
        dataset = dataset[:args.limit]

    print(f"Loading {args.model} …" + (f" + adapter {args.adapter_path}" if args.adapter_path else ""))
    model, tokenizer = load(args.model, adapter_path=args.adapter_path)

    def run_llm(prompt: str) -> str:
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
    if args.no_think:
        safe += "__nothink"
    if args.realistic:
        safe += "__realistic"
    if args.adapter_path:
        safe += "__" + Path(args.adapter_path).name
    if os.environ.get("APP_SCORING_FEW_SHOT") == "1":
        safe += "__fewshot"
    out = RESULTS / f"scoring_{safe}.json"
    out.write_text(json.dumps(rows, indent=2))
    summarize(args.model, rows, time.time() - t0, out)


def summarize(model, rows, dt, out=None):
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
    print(f"saved: {out}" if out else "")


if __name__ == "__main__":
    main()
