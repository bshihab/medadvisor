#!/usr/bin/env python3
"""Run the calibration transcripts on the iPhone's Foundation Models — via the
ios-fm-probe app — and score them against Bilal's blind gold.

Why: the mini's macOS 26.3 system model measured 48.4% single-pass / 71.0%
with the scoped verifier — but iOS 27 ships a newer base ("rebuilt from the
ground up") that scored +13.7 over the macOS model on the corrected 240 set.
This measures that newer base on the decision metric.

Workflow (two commands here, one phone session in between):

  1. python calibration_fm_ios.py prompts
       writes the 64 calibration scoring prompts into
       ../ios-fm-probe/Resources/bench_prompts.json (replacing the 240-set
       file — regenerate that one with the snippet in ios-fm-probe/README.md).
       Commit/push, then on the Air: cd tools/ios-fm-probe && xcodegen
       generate && open FMProbe.xcodeproj → run on the iPhone → tap the probe
       button → Share results JSON → AirDrop to this Mac.
       The probe grades AND self-verifies every "done" on-device in one run.

  2. python calibration_fm_ios.py compose ~/Downloads/fm_probe_ios.json
       parses the probe output with the app's parser, applies the SCOPED
       verifier locally (rejections on rubric-aggregate criteria are ignored —
       ship parity; the probe challenges everything, we decide what counts),
       excludes refusals honestly, writes calibration/judge-fm-ios/ (scoped)
       and judge-fm-ios-vfull/ (unscoped, for science). Then:
           python calibration.py report --tag fm-ios
           python calibration.py report --tag fm-ios-vfull

Caveat recorded up front: the probe's on-device verify prompt is a variant
(challenge appended to the scoring prompt) rather than the byte-identical
VERIFY_PROMPT the app ships — same content, slightly different framing.
"""
import json
import sys
from pathlib import Path

from app_scoring import build_prompt, parse_criterion
from bench_fm import looks_like_soft_refusal

HERE = Path(__file__).parent
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"
CAL = HERE / "calibration"
PROBE_PROMPTS = HERE.parent / "ios-fm-probe" / "Resources" / "bench_prompts.json"


def load():
    criteria = json.loads(RUBRIC.read_text())["criteria"]
    tmap = {p.stem: p.read_text().strip()
            for p in (CAL / "transcripts").glob("*.txt") if not p.stem.startswith("_")}
    return criteria, tmap


def cmd_prompts():
    criteria, tmap = load()
    items = [{"id": f"{tid}:{c['id']}", "prompt": build_prompt(c, tmap[tid])}
             for tid in sorted(tmap) for c in criteria]
    PROBE_PROMPTS.write_text(json.dumps(items, indent=1, ensure_ascii=False))
    print(f"wrote {len(items)} calibration prompts -> {PROBE_PROMPTS}")
    print("commit + push, then build/run the probe on the iPhone (see docstring)")


def cmd_compose(probe_json: str):
    criteria, tmap = load()
    cmap = {c["id"]: c for c in criteria}
    run = json.loads(Path(probe_json).read_text())
    print(f"device contextSize: {run.get('contextSize')}   results: {len(run['results'])}")

    rows_by_tid: dict = {tid: [] for tid in tmap}
    excluded = []
    for r in run["results"]:
        tid, cid = r["id"].split(":", 1)
        if tid not in tmap or cid not in cmap:
            print(f"  ! unknown id {r['id']} — skipped (stale bench_prompts.json on the phone?)")
            continue
        if not r["ok"] or looks_like_soft_refusal(r.get("text") or ""):
            excluded.append((tid, cid, r.get("errorKind") or "softRefusal"))
            continue
        pred, ev = parse_criterion(r["text"], tmap[tid])
        base = {"transcript": tid, "criterion": cid, "pred": pred,
                "evidence": ev, "raw": r["text"][:400]}
        rejected = pred == "met" and r.get("verifyRejected") is True
        vraw = (r.get("verifyRaw") or "")[:40]
        scoped_rej = rejected and not cmap[cid].get("aggregate")
        rows_by_tid[tid].append((
            dict(base, final="missed" if scoped_rej else pred,
                 verifier=vraw if pred == "met" and not cmap[cid].get("aggregate") else ""),
            dict(base, final="missed" if rejected else pred,
                 verifier=vraw if pred == "met" else "")))

    for tag, pick in (("judge-fm-ios", 0), ("judge-fm-ios-vfull", 1)):
        outdir = CAL / tag
        outdir.mkdir(exist_ok=True)
        for tid, pairs in rows_by_tid.items():
            outdir.joinpath(f"{tid}.json").write_text(json.dumps(
                {"model": f"apple-foundation-model (iOS, on-device, "
                          f"contextSize={run.get('contextSize')})",
                 "no_think": True, "adapter": None,
                 "rows": [p[pick] for p in pairs]}, indent=2))
        print(f"-> calibration/{tag}/")

    if excluded:
        print(f"EXCLUDED {len(excluded)} decision(s) (refusals/errors, out of denominators):")
        for t, cid, k in excluded:
            print(f"  {t} · {cid}: {k}")
    print("\nscore it:  python calibration.py report --tag fm-ios")
    print("           python calibration.py report --tag fm-ios-vfull")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "prompts":
        cmd_prompts()
    elif len(sys.argv) >= 3 and sys.argv[1] == "compose":
        cmd_compose(sys.argv[2])
    else:
        sys.exit("usage: calibration_fm_ios.py prompts | compose <probe_json>")
