#!/usr/bin/env python3
"""Apple FoundationModels (on-device system model) — realistic scoring benchmark.

Same cases, same prompts, same parser, same metrics as bench_realistic.py; the
only variable is the model. Drives the system model through fm_runner (a small
Swift CLI built automatically with swiftc — no Xcode).

Runs the phase-2 kill-checkpoints in cost order:

  --probe-context   (b) does a ~3.5k-token transcript + instructions fit the
                    context window? Pads a realistic case to several sizes and
                    reports fit/overflow per size. Run this FIRST — it's free.
  (default)         (a)+(c) refusals + stock accuracy over the realistic set.
                    Guardrail refusals are reported SEPARATELY and excluded
                    from accuracy denominators — a refusal must never be
                    laundered into a "correct missed".

Usage:
  python bench_fm.py --probe-context
  python bench_fm.py --limit 4        # smoke test
  python bench_fm.py                  # full 48-decision run
"""
import argparse, json, os as _os, re, subprocess, sys, time
from pathlib import Path

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
RESULTS = HERE / "results"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"
RUNNER_DIR = HERE / "fm_runner"
RUNNER_BIN = RUNNER_DIR / "fm_runner_bin"

MODEL_LABEL = "apple-foundation-model (system, on-device)"

# A refusal can be a thrown guardrail error OR polite refusal prose. Flag the
# latter too — it would otherwise parse as "missed" and pollute the metrics.
SOFT_REFUSAL = re.compile(
    r"(?i)\b(i(['’]m| am) (sorry|unable)|i can(['’]t|not) (help|assist|provide)|"
    r"not able to (help|assist)|cannot continue with)\b")


def looks_like_soft_refusal(text: str) -> bool:
    """Only the FIRST line is checked — an EVIDENCE quote legitimately contains
    the doctor's own "I'm sorry to hear that" (measured: 4 false positives on
    good_headache before this guard). A real refusal refuses immediately and
    produces no RESULT verdict line."""
    first = next((l for l in text.splitlines() if l.strip()), "")
    return bool(SOFT_REFUSAL.search(first)) and "result" not in first.lower()


def build_runner():
    src = RUNNER_DIR / "main.swift"
    if RUNNER_BIN.exists() and RUNNER_BIN.stat().st_mtime >= src.stat().st_mtime:
        return
    print("Building fm_runner (swiftc)…")
    subprocess.run(["swiftc", "-O", str(src), "-o", str(RUNNER_BIN)],
                   check=True, cwd=RUNNER_DIR)


class Runner:
    def _start(self):
        build_runner()
        cmd = [str(RUNNER_BIN)] + ([self.adapter] if self.adapter else [])
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1)
        hello = json.loads(self.proc.stdout.readline())
        if not hello.get("ready"):
            sys.exit(f"FoundationModels unavailable: {hello.get('availability')} "
                     "(is Apple Intelligence enabled? is the adapter's base "
                     "model version the one this OS ships?)")
        print(f"runtime: real FoundationModels | adapter: {hello.get('adapter')}")

    def __init__(self, permissive: bool = False, adapter: str | None = None):
        self.permissive = permissive
        self.adapter = adapter
        self._start()

    def call(self, rid: str, prompt: str, max_tokens: int = 180) -> dict:
        self.proc.stdin.write(json.dumps(
            {"id": rid, "prompt": prompt, "maxTokens": max_tokens,
             "permissive": self.permissive}) + "\n")
        line = self.proc.stdout.readline()
        if not line:
            sys.exit("fm_runner died mid-run")
        return json.loads(line)

    def close(self):
        self.proc.stdin.close()
        self.proc.wait()


def load_data():
    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    cases = json.loads((HERE / "realistic_cases.json").read_text())
    return criteria, cases


def approx_tokens(s: str) -> int:
    return len(s) // 4          # crude but consistent; reported as ≈


def probe_context(runner):
    """Checkpoint (b): pad a real case's transcript by repeating its turns and
    find where the full scoring prompt (prefix + transcript + one criterion)
    stops fitting. Production target: ~3.5k-token transcripts must fit."""
    criteria, cases = load_data()
    base = cases[0]["flat"]
    turns = base.splitlines()
    crit = criteria["safety_net"]      # a representative content criterion

    print("=========== FM CONTEXT-FIT PROBE ===========")
    print("target: a ~3.5k-token transcript + instructions must fit\n")
    ceiling_ok, first_fail = None, None
    for target_tokens in (600, 1500, 2500, 2800, 3000, 3200, 3400, 3500, 4000, 5000):
        transcript, i = base, 0
        while approx_tokens(transcript) < target_tokens:   # pad turn-by-turn
            transcript += "\n" + turns[i % len(turns)]
            i += 1
        prompt = build_prompt(crit, transcript)
        r = runner.call(f"ctx:{target_tokens}", prompt)
        ptok = approx_tokens(prompt)
        if r["ok"]:
            verdict = "FITS"
            ceiling_ok = target_tokens
        else:
            verdict = f"OVERFLOW ({r['errorKind']})" if r["errorKind"] == "contextWindow" \
                else f"ERROR ({r['errorKind']}: {r.get('errorDetail','')[:80]})"
            if first_fail is None:
                first_fail = target_tokens
        print(f"  transcript ≈{target_tokens:>5} tok   prompt ≈{ptok:>5} tok   "
              f"{verdict}   ({r.get('latency', 0):4.1f}s)")
    print()
    if first_fail is None:
        print("RESULT: all probed sizes fit (≥6k-token transcript).")
    else:
        print(f"RESULT: fits ≤≈{ceiling_ok} tok transcript, fails at ≈{first_fail} tok.")
        if first_fail <= 3500:
            print("KILL-CRITERION HIT: a 3.5k-token transcript does NOT fit.")


def run_bench(runner, limit=None):
    criteria, cases = load_data()
    total = sum(len(c["labels"]) for c in cases)
    if limit:
        total = min(total, limit)
    print(f"Model: {MODEL_LABEL}\nRealistic cases: {len(cases)}   criterion-calls: {total}\n")

    rows, done = [], 0
    for case in cases:
        if limit and done >= limit:
            break
        print(f"--- {case['id']}: {case['note']} ---")
        for cid, truth in case["labels"].items():
            if limit and done >= limit:
                break
            done += 1
            r = runner.call(f"{case['id']}:{cid}",
                            build_prompt(criteria[cid], case["flat"]))
            if not r["ok"]:
                mark = "REFUSED" if r["errorKind"] == "guardrail" else f"ERR:{r['errorKind']}"
                rows.append({"case": case["id"], "criterion": cid, "truth": truth,
                             "pred": None, "correct": None, "error": r["errorKind"],
                             "detail": r.get("errorDetail", "")[:200]})
                print(f"  [{done:>3}/{total}] {case['id'][:12]:<12} {cid:<18} "
                      f"truth={truth:<6} {mark}  ({r.get('latency',0):4.1f}s)")
                continue
            soft = looks_like_soft_refusal(r["text"])
            pred, _ = parse_criterion(r["text"], case["flat"])
            pred_met, truth_met = (pred == "met"), (truth == "met")
            ok = (pred_met == truth_met)
            mark = ("OK " if ok else ("OVER" if pred_met else "MISS")) + (" SOFT-REFUSAL?" if soft else "")
            print(f"  [{done:>3}/{total}] {case['id'][:12]:<12} {cid:<18} "
                  f"truth={truth:<6} pred={pred:<7} {mark}  ({r['latency']:4.1f}s)")
            rows.append({"case": case["id"], "criterion": cid, "truth": truth,
                         "pred": pred, "correct": ok, "error": None,
                         "soft_refusal": soft, "raw": r["text"]})

    RESULTS.mkdir(exist_ok=True)
    suffix = ""
    if _os.environ.get("APP_SCORING_FEW_SHOT") == "1":
        suffix += "-fewshot"
    if getattr(runner, "adapter", None):
        suffix = "-adapter-" + Path(runner.adapter).stem
    if getattr(runner, "permissive", False):
        suffix += "-permissive"
    out = RESULTS / f"realistic_apple-foundation-model{suffix}.json"
    out.write_text(json.dumps(rows, indent=2))
    summarize(rows)
    print(f"\nrows written to {out}")


def summarize(rows):
    errored = [r for r in rows if r["error"]]
    refused = [r for r in errored if r["error"] == "guardrail"]
    soft = [r for r in rows if r.get("soft_refusal")]
    scored = [r for r in rows if not r["error"]]
    print("\n============ REALISTIC SCORING SUMMARY ============")
    print(f"model:        {MODEL_LABEL}")
    print(f"refusals:     {len(refused)}/{len(rows)} hard (guardrail error), "
          f"{len(soft)} suspected soft; other errors: {len(errored) - len(refused)}")
    if not scored:
        print("no scoreable calls — nothing to summarize")
        return
    n = len(scored)
    correct = sum(r["correct"] for r in scored)
    missed = [r for r in scored if r["truth"] == "missed"]
    met = [r for r in scored if r["truth"] == "met"]
    over = sum(r["pred"] == "met" for r in missed)
    recall = sum(r["pred"] == "met" for r in met)
    print(f"accuracy:     {correct/n*100:5.1f}%   ({correct}/{n} scoreable)")
    if missed:
        print(f"over-score:   {over/len(missed)*100:5.1f}%   ({over}/{len(missed)} MISSED wrongly marked met)  ← lower better")
    if met:
        print(f"recall(met):  {recall/len(met)*100:5.1f}%   ({recall}/{len(met)} MET correctly marked met)   ← higher better")
    print("bar: the same-day Qwen2.5-7B re-baseline in results/realistic_mlx-community__Qwen2.5-7B-Instruct-4bit.json")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe-context", action="store_true")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--adapter", help="path to a trained .fmadapter package")
    ap.add_argument("--permissive", action="store_true",
                    help="run with SystemLanguageModel permissive content-transformation guardrails")
    args = ap.parse_args()

    runner = Runner(permissive=args.permissive, adapter=args.adapter)
    try:
        if args.probe_context:
            probe_context(runner)
        else:
            run_bench(runner, args.limit)
    finally:
        runner.close()


if __name__ == "__main__":
    main()
