#!/usr/bin/env python3
"""Recompute every saved 240-decision benchmark run against the gold-label
rulings in gold_audit.md.

Read-only on results/ and data/ — prints a before/after table, writes nothing.
Rulings: met (gold flips to met), missed (gold stands), na (decision excluded
for ALL models), ? (unruled — gold stands, counted so you know coverage).

Result files are auto-detected: any results/*.json that is a per-decision list
covering exactly the 240 (case, criterion) pairs of data/scoring.json.
verify_*.json files yield two lines each: the single-pass grader (pass1) and
grader + second-pass verifier (final).
"""
import argparse
import json
import re
from glob import glob
from pathlib import Path

HERE = Path(__file__).parent
VALID = {"met", "missed", "na", "?"}


def load_rulings(path: Path, gold_keys):
    pat = re.compile(r"\[\s*(case\d{3})\s*·\s*([a-z_]+)\s*\]\s*RULING:\s*(\S+)")
    rulings = {}
    for line in path.read_text().splitlines():
        m = pat.search(line)
        if not m:
            continue
        key, val = (m.group(1), m.group(2)), m.group(3).lower().strip("*_`")
        if key not in gold_keys:
            print(f"  WARNING: ruling for unknown decision {key} ignored")
            continue
        if val not in VALID:
            print(f"  WARNING: ruling {val!r} for {key} not one of met/missed/na/? — ignored")
            continue
        rulings[key] = val
    return rulings


def metrics(rows, predkey, rulings):
    n = correct = overn = overd = recn = recd = excluded = unpred = 0
    for r in rows:
        pred = r.get(predkey)
        if pred is None:  # errored call (Apple FM files) — never scored
            unpred += 1
            continue
        ruling = rulings.get((r["case"], r["criterion"]), "?")
        if ruling == "na":
            excluded += 1
            continue
        truth = "met" if ruling == "met" else r["truth"]
        pm, tm = pred == "met", truth == "met"
        n += 1
        correct += pm == tm
        if tm:
            recd += 1
            recn += pm
        else:
            overd += 1
            overn += pm
    return dict(n=n, acc=100 * correct / n,
                over=100 * overn / overd if overd else 0.0,
                recall=100 * recn / recd if recd else 0.0,
                excluded=excluded, unpred=unpred)


def label_for(fname: str) -> str:
    s = Path(fname).stem
    for pfx in ("scoring_", "realistic_", "verify_"):
        if s.startswith(pfx):
            s = s[len(pfx):]
    return s.replace("mlx-community__", "").replace("-Instruct", "").replace("-4bit", "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit", default=str(HERE / "gold_audit.md"),
                    help="rulings file (default: gold_audit.md next to this script)")
    args = ap.parse_args()

    gold = json.loads((HERE / "data" / "scoring.json").read_text())
    gold_keys = {(c["id"], cid) for c in gold for cid in c["labels"]}

    rulings = load_rulings(Path(args.audit), gold_keys)
    counts = {v: sum(1 for x in rulings.values() if x == v) for v in ("met", "missed", "na", "?")}
    print(f"rulings in {Path(args.audit).name}: "
          f"{counts['met']} met · {counts['missed']} missed · {counts['na']} na · "
          f"{counts['?']} unruled (of {len(rulings)} listed)\n")

    configs = []  # (label, rows, predkey)
    for f in sorted(glob(str(HERE / "results" / "*.json"))):
        try:
            d = json.loads(Path(f).read_text())
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if not (isinstance(d, list) and d and isinstance(d[0], dict)):
            continue
        if {(r.get("case"), r.get("criterion")) for r in d} != gold_keys:
            continue
        base = label_for(f)
        if "pass1" in d[0]:
            configs.append((base + "  [single pass]", d, "pass1"))
            configs.append((base + "  [+verifier]", d, "final"))
        elif "pred" in d[0]:
            configs.append((base, d, "pred"))

    if not configs:
        print("No per-decision result files covering the 240-decision set found.")
        return

    results = []
    for label, rows, predkey in configs:
        results.append((label, metrics(rows, predkey, {}), metrics(rows, predkey, rulings)))
    results.sort(key=lambda t: -t[2]["acc"])

    w = max(len(l) for l, _, _ in results)
    print(f"{'run':<{w}}  {'accuracy':>16}  {'over-score':>16}  {'recall(met)':>16}")
    for label, b, a in results:
        def cell(k):
            return f"{b[k]:5.1f} → {a[k]:5.1f}"
        extra = ""
        if a["excluded"]:
            extra += f"   ({a['excluded']} excluded na)"
        if a["unpred"]:
            extra += f"   ({a['unpred']} errored calls unscored)"
        print(f"{label:<{w}}  {cell('acc'):>16}  {cell('over'):>16}  {cell('recall'):>16}{extra}")

    print("\naccuracy/over/recall shown as: before → after rulings. "
          "Over-score ↓ better, recall ↑ better.")


if __name__ == "__main__":
    main()
