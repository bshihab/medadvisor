#!/usr/bin/env python3
"""Realistic-transcript scoring benchmark: runs each model over hand-written,
naturally-flowing full consultations (realistic_cases.json) with hand-labeled
ground truth — a tougher, more real test than the snippet-assembled one.

Same metrics + verbose output as bench_scoring.py.
"""
import argparse, json, os, time
from pathlib import Path

from mlx_lm import load, generate

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
RESULTS = HERE / "results"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"


def make_chat_text(tokenizer, prompt, no_think):
    """Qwen3/3.5 are reasoning models: by default they emit a long "Thinking
    Process:" block and blow the app's tight token budget before answering
    (measured: Qwen3.5-4B labeled 1 of 21 utterances). Prefer the template's
    enable_thinking=False; fall back to Qwen's /no_think soft switch if the
    template does not accept the kwarg."""
    messages = [{"role": "user", "content": prompt}]
    if no_think:
        try:
            return tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, enable_thinking=False)
        except TypeError:
            messages = [{"role": "user", "content": prompt + "\n/no_think"}]
    return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter", help="path to a trained LoRA adapter dir")
    ap.add_argument("--no-think", action="store_true",
                    help="disable reasoning mode (Qwen3/3.5) so the answer fits the budget")
    args = ap.parse_args()

    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    cases = json.loads((HERE / "realistic_cases.json").read_text())

    print(f"Loading {args.model} …")
    model, tokenizer = load(args.model, adapter_path=args.adapter)

    def run_llm(prompt: str) -> str:
        text = make_chat_text(tokenizer, prompt, args.no_think)
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
            raw = run_llm(build_prompt(criteria[cid], case["flat"]))
            pred, _ = parse_criterion(raw, case["flat"])
            pred_met, truth_met = (pred == "met"), (truth == "met")
            ok = (pred_met == truth_met)
            mark = "OK " if ok else ("OVER" if pred_met else "MISS")
            print(f"  [{done:>3}/{total}] {case['id'][:12]:<12} {cid:<18} "
                  f"truth={truth:<6} pred={pred:<7} {mark}  ({time.time()-ti:4.1f}s)")
            rows.append({"case": case["id"], "criterion": cid, "truth": truth, "pred": pred,
                         "correct": ok, "raw": raw[:400]})

    RESULTS.mkdir(exist_ok=True)
    safe = args.model.replace("/", "__")
    if os.environ.get("APP_SCORING_FEW_SHOT") == "1":
        safe += "__fewshot"
    if args.no_think:
        safe += "__nothink"
    if args.adapter:
        safe += "__lora-" + Path(args.adapter).name
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
