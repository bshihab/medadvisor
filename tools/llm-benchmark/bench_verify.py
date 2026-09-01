#!/usr/bin/env python3
"""Two-pass scoring: grade as usual, then CHALLENGE every "done" verdict.

The idea, and why it is worth a try before any more fine-tuning: every model
measured on this task fails in the same direction — over-crediting. Apple FM
stock 75%, Qwen2.5-7B 36.6%, Qwen3.5-4B 31.2% of absent behaviors wrongly
credited. Nothing has ever failed by being too strict except models we broke
ourselves. So the deficiency is scepticism, not knowledge, and scepticism can be
bought with a second call instead of new weights.

Only "done" verdicts are re-checked, so cost is ~1.4x calls rather than 2x. No
training, no toolkit, no version pinning; works on whatever model ships.

What to watch: the verifier must reject WRONG credits without rejecting right
ones. The report separates those explicitly —
  correct rejections  = truth missed, grader said met  -> over-score fixed
  wrong rejections    = truth met,    grader said met  -> recall destroyed
A verifier that just says REJECT to everything looks great on over-score and
guts recall, which is exactly how Gemma-3-4B failed the original bake-off.

Usage:
  python bench_verify.py --model mlx-community/Qwen3.5-4B-4bit --no-think
  python bench_verify.py --model mlx-community/Qwen2.5-7B-Instruct-4bit --limit 80
"""
import argparse, json, time
from pathlib import Path

from mlx_lm import load, generate

from app_scoring import (build_prompt, build_verify_prompt, parse_criterion,
                         verification_rejects)

HERE = Path(__file__).parent
DATA = HERE / "data"
RESULTS = HERE / "results"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"


def summarize(title, rows, key):
    scored = [r for r in rows if r[key] is not None]
    missed = [r for r in scored if r["truth"] == "missed"]
    met = [r for r in scored if r["truth"] == "met"]
    correct = sum((r[key] == "met") == (r["truth"] == "met") for r in scored)
    over = sum(r[key] == "met" for r in missed)
    rec = sum(r[key] == "met" for r in met)
    print(f"{title:<26} acc {correct/len(scored)*100:5.1f}%  "
          f"over {over/len(missed)*100:5.1f}% ({over}/{len(missed)})  "
          f"recall {rec/len(met)*100:5.1f}% ({rec}/{len(met)})")
    return dict(acc=correct / len(scored) * 100,
                over=over / len(missed) * 100 if missed else 0,
                recall=rec / len(met) * 100 if met else 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--no-think", action="store_true")
    ap.add_argument("--limit", type=int, default=0, help="cap criterion calls (0 = all 240)")
    args = ap.parse_args()

    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    dataset = json.loads((DATA / "scoring.json").read_text())

    print(f"Loading {args.model} …")
    model, tokenizer = load(args.model)

    def run(prompt, max_tokens):
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
        return generate(model, tokenizer, prompt=text, max_tokens=max_tokens, verbose=False)

    rows, done, verifications = [], 0, 0
    t0 = time.time()
    for case in dataset:
        for cid, truth in case["labels"].items():
            if args.limit and done >= args.limit:
                break
            done += 1
            raw = run(build_prompt(criteria[cid], case["flat"]), 180)
            pred, evidence = parse_criterion(raw, case["flat"])

            final, verdict = pred, ""
            if pred == "met":
                # Second pass — only "done" verdicts are challenged.
                vraw = run(build_verify_prompt(criteria[cid], case["flat"], evidence), 12)
                verifications += 1
                if verification_rejects(vraw):
                    final, verdict = "missed", vraw.strip()[:20]
            rows.append({"case": case["id"], "criterion": cid, "truth": truth,
                         "pass1": pred, "final": final, "evidence": (evidence or "")[:120],
                         "verifier": verdict})
            flag = ""
            if pred == "met" and final == "missed":
                flag = " ✓fixed" if truth == "missed" else " ✗LOST"
            print(f"  [{done:>3}] {case['id']:<8} {cid:<20} truth={truth:<6} "
                  f"p1={pred:<7} final={final:<7}{flag}")
        if args.limit and done >= args.limit:
            break

    print(f"\n{'='*74}")
    before = summarize("BEFORE (single pass)", rows, "pass1")
    after = summarize("AFTER (+ verification)", rows, "final")

    flips = [r for r in rows if r["pass1"] == "met" and r["final"] == "missed"]
    good = [r for r in flips if r["truth"] == "missed"]
    bad = [r for r in flips if r["truth"] == "met"]
    print(f"\nverifier ran on {verifications} 'done' verdicts "
          f"({verifications/done*100:.0f}% of calls -> {1 + verifications/done:.2f}x cost)")
    print(f"  rejected {len(flips)}:  {len(good)} correct (over-score fixed)  "
          f"{len(bad)} WRONG (real credit destroyed)")
    if flips:
        print(f"  precision of rejections: {len(good)/len(flips)*100:.0f}%")
    print(f"\nΔ accuracy {after['acc']-before['acc']:+.1f}  "
          f"Δ over-score {after['over']-before['over']:+.1f}  "
          f"Δ recall {after['recall']-before['recall']:+.1f}")
    print(f"wall-clock {time.time()-t0:.0f}s")

    RESULTS.mkdir(exist_ok=True)
    safe = args.model.replace("/", "__") + ("__nothink" if args.no_think else "")
    out = RESULTS / f"verify_{safe}.json"
    out.write_text(json.dumps(rows, indent=2))
    print(f"rows -> {out}")


if __name__ == "__main__":
    main()
