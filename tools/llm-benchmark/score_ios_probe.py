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

# Kept per test set — mixing a 48-case baseline with a 240-case result is an
# apples-to-oranges comparison, and every model scores worse on the 240 set.
BASELINES_48 = [
    ("Qwen2.5-7B — ships today", 87.5, 13.3, 88.9),
    ("Qwen3.5-4B (no-think)", 89.6, 16.7, 100.0),
    ("Apple FM stock — macOS 26.3", 54.3, 75.0, 100.0),
    ("Apple FM + adapter — macOS 26.3", 93.8, 6.7, 94.4),
]
BASELINES_240 = [
    ("Qwen3.5-4B + verification pass", 90.0, 11.6, 91.4),
    ("Qwen3.5-4B (no-think)", 85.4, 31.2, 100.0),
    ("Qwen2.5-7B + few-shot", 83.8, 24.1, 90.6),
    ("Qwen2.5-7B — ships today", 79.2, 36.6, 93.0),
    ("Qwen2.5-3B", 70.8, 35.7, 76.6),
    ("Apple FM stock — macOS 26.3", 52.1, 97.3, 96.8),
    ("Apple FM + adapter — macOS 26.3 *", 98.3, 3.6, 100.0),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("probe_json")
    args = ap.parse_args()

    run = json.loads(Path(args.probe_json).read_text())
    # Merge truth from BOTH sets, so the same scorer handles a 48-decision
    # realistic run and a 240-decision snippet run with no flag — the prompt ids
    # are disjoint ("good_headache:..." vs "case000:...").
    cases = json.loads((HERE / "realistic_cases.json").read_text())
    snippet_path = HERE / "data" / "scoring.json"
    if snippet_path.exists():
        cases = cases + json.loads(snippet_path.read_text())
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
        # Second pass, when the probe ran one: a REJECT turns a "met" into a miss.
        # verifyRejected is absent on runs from before the verification pass
        # existed, and None when pass 1 was not "done" (only "done" is challenged).
        final = pred
        if pred == "met" and r.get("verifyRejected") is True:
            final = "missed"
        rows.append({"case": case, "criterion": crit, "truth": t, "pred": pred,
                     "final": final,
                     "correct": (pred == "met") == (t == "met"),
                     "correct_final": (final == "met") == (t == "met"),
                     "verified": r.get("verifyRejected"),
                     "verify_raw": (r.get("verifyRaw") or "")[:60],
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

    print(f"\nset: {len(scored)} scoreable decisions"
          + ("  (240-decision snippet set)" if len(rows) > 100 else "  (48-decision realistic set)"))
    print(f"\n{'model':<38} {'acc':>7} {'over':>7} {'recall':>7}")
    print("-" * 62)
    for name, a, o, r_ in (BASELINES_240 if len(rows) > 100 else BASELINES_48):
        print(f"{name:<38} {a:>6.1f}% {o:>6.1f}% {r_:>6.1f}%")
    print(f"{'>> Apple FM stock — THIS DEVICE':<38} {acc:>6.1f}% {over:>6.1f}% {rec:>6.1f}%")
    print("-" * 62)
    if len(rows) > 100:
        print("* adapter number is an UPPER BOUND: the 240-set is the same synthetic\n  genre its training data was built from, plus phrase-level overlap.")

    # --- verification pass, if this run had one -------------------------
    challenged = [r for r in scored if r.get("verified") is not None]
    if challenged:
        def summar(key):
            missed_ = [r for r in scored if r["truth"] == "missed"]
            met_ = [r for r in scored if r["truth"] == "met"]
            return (sum(r[key] == "met" for r in missed_) / len(missed_) * 100 if missed_ else 0,
                    sum(r[key] == "met" for r in met_) / len(met_) * 100 if met_ else 0)
        acc1 = sum(r["correct"] for r in scored) / len(scored) * 100
        acc2 = sum(r["correct_final"] for r in scored) / len(scored) * 100
        over1, rec1 = summar("pred")
        over2, rec2 = summar("final")
        flips = [r for r in scored if r["pred"] == "met" and r["final"] == "missed"]
        good = [r for r in flips if r["truth"] == "missed"]
        bad = [r for r in flips if r["truth"] == "met"]
        print("\n============ VERIFICATION PASS (two-pass scoring) ============")
        print(f"BEFORE (single pass)   acc {acc1:5.1f}%  over {over1:5.1f}%  recall {rec1:5.1f}%")
        print(f"AFTER  (+ verify)      acc {acc2:5.1f}%  over {over2:5.1f}%  recall {rec2:5.1f}%")
        print(f"\nverifier ran on {len(challenged)} 'done' verdicts "
              f"({len(challenged)/len(scored)*100:.0f}% of calls -> "
              f"{1 + len(challenged)/len(scored):.2f}x cost)")
        print(f"  rejected {len(flips)}:  {len(good)} correct (over-score fixed)  "
              f"{len(bad)} WRONG (real credit destroyed)")
        if flips:
            print(f"  precision of rejections: {len(good)/len(flips)*100:.0f}%")
        print(f"\nBar to beat — Qwen 3.5-4B stock on this set: acc 85.4%")
        print("A verifier that REJECTs everything looks great on over-score and guts")
        print("recall; that is why both columns are shown.")

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
