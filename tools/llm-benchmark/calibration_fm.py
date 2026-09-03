#!/usr/bin/env python3
"""Apple Foundation Models (stock system model) + scoped verifier, measured on
the calibration transcripts against Bilal's blind gold.

The question this answers (2026-09-03): could the download-free system model,
wearing the same runtime verifier trick that lifted our stock Qwen from 65.1%
to 84.1%, be a viable judge — without ever touching the FM adapter treadmill
(adapters are version-locked to the OS's base model and licensed
non-redistributable)?

Pass 1 grades all 16 criteria per transcript with the app's exact prompt and
parser; pass 2 challenges every 'done' verdict with the CONFIRM/REJECT verify
prompt, skipping rubric-flagged aggregate criteria (ship parity). Refusals —
thrown guardrail errors or polite refusal prose — are EXCLUDED from the rows
(never laundered into 'missed'); the report's coverage warning surfaces them.

Writes calibration/judge-fm/<tid>.json; score with:
    python calibration.py report --tag fm
"""
import json
from pathlib import Path

from app_scoring import (build_prompt, build_verify_prompt, parse_criterion,
                         verification_rejects)
from bench_fm import Runner, looks_like_soft_refusal

HERE = Path(__file__).parent
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"
CAL = HERE / "calibration"


def main():
    criteria = json.loads(RUBRIC.read_text())["criteria"]
    tmap = {p.stem: p.read_text().strip()
            for p in (CAL / "transcripts").glob("*.txt") if not p.stem.startswith("_")}
    runner = Runner()

    outdir = CAL / "judge-fm"
    outdir.mkdir(exist_ok=True)
    excluded, verified, rejected = [], 0, 0
    for tid in sorted(tmap):
        rows = []
        for c in criteria:
            r = runner.call(f"{tid}:{c['id']}", build_prompt(c, tmap[tid]), 180)
            if not r.get("ok") or looks_like_soft_refusal(r.get("text", "")):
                kind = r.get("errorKind", "softRefusal") if not r.get("ok") else "softRefusal"
                excluded.append((tid, c["id"], kind))
                print(f"  {tid} {c['id']:<20} EXCLUDED ({kind})")
                continue
            pred, ev = parse_criterion(r["text"], tmap[tid])
            row = {"transcript": tid, "criterion": c["id"], "pred": pred,
                   "evidence": ev, "raw": r["text"][:400]}
            # Scoped verify, inline: only 'met' verdicts, never aggregate criteria.
            if pred == "met" and not c.get("aggregate"):
                v = runner.call(f"{tid}:{c['id']}:verify",
                                build_verify_prompt(c, tmap[tid], ev or ""), 16)
                verified += 1
                reply = (v.get("text") or "").strip() if v.get("ok") else ""
                rej = verification_rejects(reply)   # fail-open on error/garble
                rejected += rej
                row["final"] = "missed" if rej else "met"
                row["verifier"] = reply[:40]
            else:
                row["final"] = pred
                row["verifier"] = ""
            print(f"  {tid} {c['id']:<20} {pred:<8}"
                  f"{' -> ' + row['final'] if row['final'] != pred else ''}")
            rows.append(row)
        (outdir / f"{tid}.json").write_text(json.dumps(
            {"model": "apple-foundation-model (system, on-device)",
             "no_think": True, "adapter": None, "rows": rows}, indent=2))
    runner.close()

    print(f"\nverify calls: {verified} ({rejected} rejected)")
    if excluded:
        print(f"EXCLUDED {len(excluded)} decision(s) — refusals/errors, "
              "kept out of the denominators:")
        for t, cid, k in excluded:
            print(f"  {t} · {cid}: {k}")
    print("\nscore it:  python calibration.py report --tag fm")


if __name__ == "__main__":
    main()
