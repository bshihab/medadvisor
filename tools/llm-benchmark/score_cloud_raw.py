#!/usr/bin/env python3
"""Score the raw generation output from a cloud training run (modal_train.py).

The GPU only generates text; scoring happens HERE with the app's own parser and
evidence guardrail, so a cloud-trained adapter is measured by exactly the same
code path as Qwen, stock FM, and the dose tests. No metric lives on the GPU.

Usage:
  python score_cloud_raw.py                        # every results/cloud_bench_raw_*.txt
  python score_cloud_raw.py --file results/cloud_bench_raw_lr1e-3.txt
"""
import argparse, json, re
from pathlib import Path

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
RESULTS = HERE / "results"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"

RESP = re.compile(r"Response for prompt (\d+):")

# The bar and the prior runs, for a single comparable table.
BASELINES = [
    ("Qwen2.5-7B Q4 (ships today)", 87.5, 13.3, 88.9),
    ("Apple FM stock", 54.3, 75.0, 100.0),
    ("Apple FM + adapter, dose48 strict", 62.5, 0.0, 0.0),
    ("Apple FM + adapter, dose48 balanced", 68.8, 0.0, 16.7),
]


def index_cases():
    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    cases = json.loads((HERE / "realistic_cases.json").read_text())
    idx = []
    for case in cases:
        for cid, truth in case["labels"].items():
            idx.append((case["id"], cid, truth, case["flat"]))
    # Sanity: the prompt order must match what was sent to the GPU.
    _ = [build_prompt(criteria[c], f) for _, c, _, f in idx]
    return idx


def score(path: Path, idx):
    text = path.read_text()
    parts = RESP.split(text)
    responses = {}
    for i in range(1, len(parts) - 1, 2):
        responses[int(parts[i])] = parts[i + 1].replace("<turn_end>", "").strip()

    rows = []
    for pos, (case_id, cid, truth, flat) in enumerate(idx):
        raw = responses.get(pos)
        if raw is None:
            rows.append({"case": case_id, "criterion": cid, "truth": truth,
                         "pred": None, "correct": None, "error": "no-response"})
            continue
        pred, _ = parse_criterion(raw, flat)
        rows.append({"case": case_id, "criterion": cid, "truth": truth,
                     "pred": pred, "correct": (pred == "met") == (truth == "met"),
                     "error": None, "raw": raw[:400]})

    scored = [r for r in rows if not r["error"]]
    missed = [r for r in scored if r["truth"] == "missed"]
    met = [r for r in scored if r["truth"] == "met"]
    acc = sum(r["correct"] for r in scored) / len(scored) * 100 if scored else 0
    over = sum(r["pred"] == "met" for r in missed) / len(missed) * 100 if missed else 0
    rec = sum(r["pred"] == "met" for r in met) / len(met) * 100 if met else 0

    tag = path.stem.replace("cloud_bench_raw_", "")
    (RESULTS / f"realistic_fm-adapter-cloud-{tag}.json").write_text(json.dumps(rows, indent=2))
    return tag, acc, over, rec, len(rows) - len(scored), rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file")
    args = ap.parse_args()

    idx = index_cases()
    files = ([Path(args.file)] if args.file
             else sorted(RESULTS.glob("cloud_bench_raw_*.txt")))
    if not files:
        raise SystemExit("no cloud_bench_raw_*.txt in results/ — run modal_train.py first")

    scored = [score(f, idx) for f in files]

    print("\n=================== PHASE 3 RESULTS ===================")
    print(f"{'model':<40} {'acc':>7} {'over':>7} {'recall':>7}")
    print("-" * 64)
    for name, a, o, r in BASELINES:
        print(f"{name:<40} {a:>6.1f}% {o:>6.1f}% {r:>6.1f}%")
    for tag, a, o, r, errs, _ in scored:
        label = f"Apple FM + adapter, FULL 569 [{tag}]"
        print(f"{label:<40} {a:>6.1f}% {o:>6.1f}% {r:>6.1f}%"
              + (f"   ({errs} errors)" if errs else ""))
    print("-" * 64)
    print("over-score = absent behaviors wrongly credited (lower better)")
    print("recall     = genuinely-done behaviors correctly credited (higher better)")

    for tag, a, o, r, _, rows in scored:
        wrong = [x for x in rows if x["correct"] is False]
        print(f"\n[{tag}] {len(wrong)} wrong of {len(rows)}:")
        for x in wrong[:12]:
            print(f"   {x['case'][:12]:<12} {x['criterion']:<20} "
                  f"truth={x['truth']:<7} pred={x['pred']}")
        if len(wrong) > 12:
            print(f"   … and {len(wrong) - 12} more")


if __name__ == "__main__":
    main()
