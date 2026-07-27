#!/usr/bin/env python3
"""Score the JSON produced by tools/ios-fm-probe on a real iPhone.

The phone only replays prompts and records raw output; every metric is computed
HERE with the app's own parser + evidence guardrail, so an on-device result is
directly comparable to Qwen, stock FM on macOS, and the adapter runs.

Usage:
  python score_ios_probe.py ~/Downloads/fm_probe_ios.json
"""
import argparse, json
from pathlib import Path

from app_scoring import parse_criterion

HERE = Path(__file__).parent
RESULTS = HERE / "results"

BASELINES = [
    ("Qwen2.5-7B Q4 — ships today", 87.5, 13.3, 88.9),
    ("Qwen2.5-7B + few-shot (240-set)", 83.8, 24.1, 90.6),
    ("Apple FM stock — macOS 26.3", 54.3, 75.0, 100.0),
    ("Apple FM + adapter — macOS 26.3", 93.8, 6.7, 94.4),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("probe_json")
    args = ap.parse_args()

    run = json.loads(Path(args.probe_json).read_text())
    cases = json.loads((HERE / "realistic_cases.json").read_text())
    truth = {f"{c['id']}:{cid}": lab
             for c in cases for cid, lab in c["labels"].items()}

    rows, refusals, errors = [], 0, 0
    for r in run["results"]:
        t = truth.get(r["id"])
        if t is None:
            print(f"  ! unknown prompt id {r['id']} — skipped")
            continue
        case, crit = r["id"].split(":", 1)
        flat = next(c["flat"] for c in cases if c["id"] == case)
        if not r["ok"]:
            if r.get("errorKind") == "guardrail":
                refusals += 1
            else:
                errors += 1
            rows.append({"case": case, "criterion": crit, "truth": t,
                         "pred": None, "correct": None,
                         "error": r.get("errorKind"),
                         "detail": (r.get("errorDetail") or "")[:200]})
            continue
        pred, _ = parse_criterion(r["text"], flat)
        rows.append({"case": case, "criterion": crit, "truth": t, "pred": pred,
                     "correct": (pred == "met") == (t == "met"),
                     "error": None, "raw": r["text"][:400],
                     "seconds": r.get("seconds"),
                     "outputTokens": r.get("outputTokens")})

    scored = [r for r in rows if not r["error"]]
    missed = [r for r in scored if r["truth"] == "missed"]
    met = [r for r in scored if r["truth"] == "met"]
    acc = sum(r["correct"] for r in scored) / len(scored) * 100 if scored else 0
    over = sum(r["pred"] == "met" for r in missed) / len(missed) * 100 if missed else 0
    rec = sum(r["pred"] == "met" for r in met) / len(met) * 100 if met else 0

    print("\n================= ON-DEVICE (iOS) STOCK MODEL =================")
    print(f"device:        {run.get('device')}   iOS {run.get('systemVersion')}")
    print(f"availability:  {run.get('modelAvailability')}")
    ctx = run.get("contextSize")
    print(f"context size:  {ctx if ctx else 'API unavailable'}"
          + ("   <- vs ~4096 measured on macOS 26.3" if ctx else ""))
    print(f"refusals:      {refusals} hard (guardrail) · other errors: {errors}")
    toks = sum(r.get("outputTokens") or 0 for r in scored)
    secs = sum(r.get("seconds") or 0 for r in scored)
    if secs:
        print(f"speed:         {toks/secs:5.1f} tok/s   ({secs:.0f}s generating, "
              f"{run.get('wallSeconds', 0):.0f}s wall)")
    print(f"thermal:       {run.get('startedThermal')} -> {run.get('finishedThermal')}")
    b0, b1 = run.get("startedBattery", 0), run.get("finishedBattery", 0)
    print(f"battery:       {b0*100:.0f}% -> {b1*100:.0f}%  ({(b0-b1)*100:.1f} points for "
          f"{len(scored)} criterion calls ≈ 3 analyses)")

    print(f"\n{'model':<38} {'acc':>7} {'over':>7} {'recall':>7}")
    print("-" * 62)
    for name, a, o, r_ in BASELINES:
        print(f"{name:<38} {a:>6.1f}% {o:>6.1f}% {r_:>6.1f}%")
    print(f"{'>> Apple FM stock — THIS DEVICE':<38} {acc:>6.1f}% {over:>6.1f}% {rec:>6.1f}%")
    print("-" * 62)

    wrong = [r for r in scored if r["correct"] is False]
    print(f"\n{len(wrong)} wrong of {len(scored)} scoreable:")
    for w in wrong[:14]:
        print(f"   {w['case'][:12]:<12} {w['criterion']:<20} "
              f"truth={w['truth']:<7} pred={w['pred']}")
    if len(wrong) > 14:
        print(f"   … and {len(wrong)-14} more")

    RESULTS.mkdir(exist_ok=True)
    out = RESULTS / f"realistic_apple-fm-stock-ios{run.get('systemVersion','?')}.json"
    out.write_text(json.dumps(rows, indent=2))
    print(f"\nrows -> {out}")
    print("\nRead: if accuracy is at/above Qwen and over-score is low, the OS-27 "
          "model may be good enough WITHOUT any adapter — no toolkit, no\n"
          "entitlement, no 160MB download, no version pinning.")


if __name__ == "__main__":
    main()
