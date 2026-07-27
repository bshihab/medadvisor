#!/usr/bin/env python3
"""Benchmark a TRAINED Apple FM adapter checkpoint on the held-out realistic set.

Runs the same 48 criterion decisions as bench_realistic.py / bench_fm.py, but
through the adapter toolkit's examples/generate.py (torch/MPS, greedy), loading
the base model + the given adapter checkpoint. Reuses app_scoring for prompts
and parsing, so the only variable vs the stock-FM run is the adapter.

Usage:
  python bench_fm_adapter.py --checkpoint /path/to/adapter-final.pt --tag dose48
  python bench_fm_adapter.py --checkpoint ... --tag full --limit 8   # smoke
"""
import argparse, json, re, subprocess, sys
from pathlib import Path

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
RESULTS = HERE / "results"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"
TOOLKIT = HERE.parent / "adapter-training" / "adapter_training_toolkit_v26_0_0"

RESP_MARKER = re.compile(r"Response for prompt (\d+):")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--tag", required=True, help="label for the results file")
    ap.add_argument("--limit", type=int)
    args = ap.parse_args()

    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    cases = json.loads((HERE / "realistic_cases.json").read_text())

    index = []          # position -> (case_id, criterion_id, truth, flat)
    lines = []
    for case in cases:
        for cid, truth in case["labels"].items():
            if args.limit and len(index) >= args.limit:
                break
            index.append((case["id"], cid, truth, case["flat"]))
            lines.append(json.dumps(
                [{"role": "user", "content": build_prompt(criteria[cid], case["flat"])}],
                ensure_ascii=False))

    prompts_path = HERE / "data" / "adapter" / f"bench_prompts_{args.tag}.jsonl"
    prompts_path.write_text("\n".join(lines) + "\n")
    print(f"{len(index)} prompts -> {prompts_path}\nRunning toolkit generate (loads ~7GB model once)…")

    proc = subprocess.run(
        [str(TOOLKIT / ".venv/bin/python"), "-m", "examples.generate",
         "--prompt", str(prompts_path), "--checkpoint", args.checkpoint,
         "--precision", "bf16", "--temperature", "0", "--max-new-tokens", "180"],
        cwd=TOOLKIT, capture_output=True, text=True)
    out = proc.stdout + "\n" + proc.stderr
    if proc.returncode != 0:
        sys.exit(f"generate failed (exit {proc.returncode}); tail:\n" + out[-1500:])

    # Responses may span lines: capture between markers.
    responses = {}
    parts = RESP_MARKER.split(out)
    # parts = [pre, idx0, text0, idx1, text1, ...]
    for i in range(1, len(parts) - 1, 2):
        text = parts[i + 1]
        # Trim trailing logger noise from the last chunk of each block.
        responses[int(parts[i])] = text.replace("<turn_end>", "").strip()

    rows = []
    for pos, (case_id, cid, truth, flat) in enumerate(index):
        raw = responses.get(pos)
        if raw is None:
            rows.append({"case": case_id, "criterion": cid, "truth": truth,
                         "pred": None, "correct": None, "error": "no-response"})
            continue
        pred, _ = parse_criterion(raw, flat)
        ok = (pred == "met") == (truth == "met")
        rows.append({"case": case_id, "criterion": cid, "truth": truth,
                     "pred": pred, "correct": ok, "error": None, "raw": raw[:400]})
        mark = "OK " if ok else ("OVER" if pred == "met" else "MISS")
        print(f"  {case_id[:12]:<12} {cid:<20} truth={truth:<6} pred={pred:<7} {mark}")

    RESULTS.mkdir(exist_ok=True)
    outfile = RESULTS / f"realistic_fm-adapter-{args.tag}.json"
    outfile.write_text(json.dumps(rows, indent=2))

    scored = [r for r in rows if not r["error"]]
    missed = [r for r in scored if r["truth"] == "missed"]
    met = [r for r in scored if r["truth"] == "met"]
    print("\n============ REALISTIC SCORING SUMMARY ============")
    print(f"model:        apple-fm + adapter [{args.tag}] ({args.checkpoint})")
    print(f"errors:       {len(rows) - len(scored)}")
    if scored:
        print(f"accuracy:     {sum(r['correct'] for r in scored)/len(scored)*100:5.1f}%   ({sum(r['correct'] for r in scored)}/{len(scored)})")
    if missed:
        over = sum(r["pred"] == "met" for r in missed)
        print(f"over-score:   {over/len(missed)*100:5.1f}%   ({over}/{len(missed)})  [stock FM: 75.0%]")
    if met:
        rec = sum(r["pred"] == "met" for r in met)
        print(f"recall(met):  {rec/len(met)*100:5.1f}%   ({rec}/{len(met)})  [stock FM: 100%]")
    print("bar: Qwen re-baseline 87.5% acc / 13.3% over / 88.9% recall")
    print(f"rows -> {outfile}")


if __name__ == "__main__":
    main()
