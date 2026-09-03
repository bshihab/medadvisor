#!/usr/bin/env python3
"""Human-vs-judge calibration study — the true validation the README defers to.

Compares the shipped judge's per-criterion verdicts against blind human scores
on FRESH role-played consultations (never real patient audio, never material
from the benchmark or training sets).

Protocol — order matters, the human must not see judge output before scoring:
  1. Put transcripts in calibration/transcripts/<name>.txt
     (plain text, "Doctor: ..." / "Patient: ..." lines; files starting with
     "_" are ignored)
  2. python calibration.py sheet          -> calibration/sheets/<name>.md
  3. Human fills every "SCORE: ?" (met / partial / missed / na) — BEFORE step 4
  4. python calibration.py judge          -> calibration/judge/<name>.json
     (needs the benchmark venv with mlx-lm; run on the Air)
  5. python calibration.py report         -> calibration/REPORT.md

Agreement is computed on the binary the app cares about (met vs not-met);
exact-status agreement is reported alongside. Human "na" rows are excluded
from the stats and listed. Read-only on everything outside calibration/.
"""
import argparse
import json
import re
import time
from pathlib import Path

HERE = Path(__file__).parent
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"
DEFAULT_MODEL = "mlx-community/Qwen3.5-4B-4bit"

SCORE_RE = re.compile(r"\[\s*([\w-]+)\s*·\s*([a-z_]+)\s*\]\s*SCORE:\s*(\S+)")
VALID_HUMAN = {"met", "partial", "missed", "na", "?"}
# The app's prompt says done/partial/missed; accept "done" as "met" in sheets.
ALIAS = {"done": "met"}


def criteria_in_order():
    return json.loads(RUBRIC.read_text())["criteria"]


def transcripts(base: Path):
    for f in sorted((base / "transcripts").glob("*.txt")):
        if not f.stem.startswith("_"):
            yield f.stem, f.read_text().strip()


def cmd_sheet(base: Path):
    outdir = base / "sheets"
    outdir.mkdir(parents=True, exist_ok=True)
    crits = criteria_in_order()
    n = 0
    for tid, text in transcripts(base):
        out = outdir / f"{tid}.md"
        if out.exists():
            print(f"  keeping existing sheet {out.name} (delete it to regenerate)")
            continue
        lines = [f"# Blind scoring sheet — {tid}", "",
                 "Score every criterion from the transcript below, BEFORE looking",
                 "at any judge output. Replace each `?` with: met / partial / missed / na.",
                 "The app treats partial and missed both as not-met; na = criterion",
                 "does not apply to this consultation.", "",
                 "## Transcript", "", "```", text, "```", "", "## Scores", ""]
        for c in crits:
            lines.append(f"**{c['id']}** — {c['prompt']}")
            good = c.get("whatGoodLooksLike")
            if good:
                lines.append(f"  *good looks like: {good}*")
            lines.append(f"- [{tid} · {c['id']}] SCORE: ?")
            lines.append("")
        out.write_text("\n".join(lines))
        print(f"  wrote {out}")
        n += 1
    print(f"{n} new sheet(s). Fill them in before running `judge`." if n
          else "No new sheets (no transcripts found, or all sheets exist).")


def make_runner(model_id: str, no_think: bool, adapter_path: str = None):
    from mlx_lm import load, generate  # lazy: sheet/report need no venv

    print(f"Loading {model_id} …" + (f" + adapter {adapter_path}" if adapter_path else ""))
    model, tokenizer = load(model_id, adapter_path=adapter_path)

    def run(prompt: str, max_tokens: int = 180) -> str:
        messages = [{"role": "user", "content": prompt}]
        if no_think:
            try:
                text = tokenizer.apply_chat_template(
                    messages, add_generation_prompt=True, enable_thinking=False)
            except TypeError:
                text = tokenizer.apply_chat_template(
                    [{"role": "user", "content": prompt + "\n/no_think"}],
                    add_generation_prompt=True)
        else:
            text = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        return generate(model, tokenizer, prompt=text, max_tokens=max_tokens, verbose=False)

    return run


def cmd_judge(base: Path, model_id: str, no_think: bool, jdir: str = "judge",
              adapter_path: str = None):
    from app_scoring import build_prompt, parse_criterion

    outdir = base / jdir
    outdir.mkdir(parents=True, exist_ok=True)
    crits = criteria_in_order()
    run = make_runner(model_id, no_think, adapter_path)

    for tid, text in transcripts(base):
        out = outdir / f"{tid}.json"
        if out.exists():
            print(f"  keeping existing {out.name} (delete it to re-run)")
            continue
        rows = []
        for c in crits:
            t0 = time.time()
            raw = run(build_prompt(c, text))
            pred, evidence = parse_criterion(raw, text)
            rows.append({"transcript": tid, "criterion": c["id"], "pred": pred,
                         "evidence": evidence, "raw": raw[:400]})
            print(f"  {tid} {c['id']:<20} {pred:<8} ({time.time() - t0:4.1f}s)")
        out.write_text(json.dumps({"model": model_id, "no_think": no_think,
                                   "adapter": adapter_path, "rows": rows}, indent=2))
        print(f"  -> {out}")


def cmd_verify(base: Path, model_id: str, no_think: bool, jdir: str = "judge",
               adapter_path: str = None):
    """Second pass, fully automated: challenge every 'met' verdict already in
    judge/*.json with one 12-token CONFIRM/REJECT call. No human input."""
    from app_scoring import build_verify_prompt, verification_rejects

    crits = {c["id"]: c for c in criteria_in_order()}
    tmap = dict(transcripts(base))
    files = sorted((base / jdir).glob("*.json"))
    if not files:
        print(f"No judge output in {jdir}/ — run `judge` first.")
        return
    run = None
    for f in files:
        d = json.loads(f.read_text())
        if all("final" in r for r in d["rows"]):
            print(f"  keeping existing verification in {f.name} (delete the file's 'final' fields to re-run)")
            continue
        if run is None:
            run = make_runner(model_id, no_think, adapter_path)
        checks = 0
        for r in d["rows"]:
            # Ship parity: aggregate criteria (rubric flag) are never verified —
            # no single quote can prove a whole-visit behaviour, and the sceptic
            # wrongly rejects real credit there (measured 1 fixed / 3 destroyed).
            if crits[r["criterion"]].get("aggregate"):
                r["final"] = r["pred"]
                r["verifier"] = ""
                continue
            if r["pred"] == "met":
                vraw = run(build_verify_prompt(crits[r["criterion"]],
                                               tmap[r["transcript"]],
                                               r.get("evidence") or ""), max_tokens=12)
                checks += 1
                rejected = verification_rejects(vraw)
                r["final"] = "missed" if rejected else "met"
                r["verifier"] = vraw.strip()[:40]
                print(f"  {r['transcript']} {r['criterion']:<20} "
                      f"{'REJECTED -> missed' if rejected else 'confirmed'}")
            else:
                r["final"] = r["pred"]
                r["verifier"] = ""
        d["verify_model"] = model_id
        f.write_text(json.dumps(d, indent=2))
        print(f"  -> {f.name} ({checks} verdicts challenged)")


def load_human(base: Path):
    scores = {}
    for f in sorted((base / "sheets").glob("*.md")):
        for line in f.read_text().splitlines():
            m = SCORE_RE.search(line)
            if not m:
                continue
            val = ALIAS.get(m.group(3).lower().strip("*_`"), m.group(3).lower().strip("*_`"))
            if val not in VALID_HUMAN:
                print(f"  WARNING: {f.name}: score {val!r} for {m.group(2)} not "
                      "met/partial/missed/na — treated as unscored")
                val = "?"
            scores[(m.group(1), m.group(2))] = val
    return scores


def cmd_report(base: Path, jdir: str = "judge"):
    human = load_human(base)
    if not human:
        print("No filled sheets found — run `sheet` and score them first.")
        return
    judged, meta = {}, set()
    for f in sorted((base / jdir).glob("*.json")):
        d = json.loads(f.read_text())
        meta.add((d.get("model"), d.get("no_think"), d.get("adapter")))
        for r in d["rows"]:
            judged[(r["transcript"], r["criterion"])] = r
    if not judged:
        print("No judge output found — run `judge` first.")
        return

    keys = sorted(set(human) & set(judged))
    unscored = [k for k in keys if human[k] == "?"]
    na = [k for k in keys if human[k] == "na"]
    scored = [k for k in keys if human[k] not in ("?", "na")]

    def bin_(s):
        return "met" if s == "met" else "not-met"

    agree_b = [k for k in scored if bin_(human[k]) == bin_(judged[k]["pred"])]
    agree_x = [k for k in scored if human[k] == judged[k]["pred"]]
    dis = [k for k in scored if k not in set(agree_b)]
    verified = all("final" in judged[k] for k in scored)

    lines = ["# Calibration report — human vs judge"
             + ("" if jdir == "judge" else f" ({jdir})"), "",
             "Judge run(s): " + ", ".join(
                 f"{m} (no_think={nt}" + (f", adapter={a}" if a else "") + ")"
                 for m, nt, a in sorted(meta, key=str)), "",
             f"- decisions compared: {len(scored)}"
             f" (+{len(na)} human-na excluded, +{len(unscored)} unscored)",
             f"- **binary agreement (met vs not-met): "
             f"{100 * len(agree_b) / len(scored):.1f}%  ({len(agree_b)}/{len(scored)})**",
             f"- exact-status agreement: {100 * len(agree_x) / len(scored):.1f}%"
             f"  ({len(agree_x)}/{len(scored)})", ""]

    if verified:
        agree_f = [k for k in scored if bin_(human[k]) == bin_(judged[k]["final"])]
        flips = [k for k in scored
                 if judged[k]["pred"] == "met" and judged[k]["final"] == "missed"]
        good = [k for k in flips if bin_(human[k]) == "not-met"]
        bad = [k for k in flips if bin_(human[k]) == "met"]
        lines += [f"- **with verifier: {100 * len(agree_f) / len(scored):.1f}%"
                  f"  ({len(agree_f)}/{len(scored)})** — verifier rejected "
                  f"{len(flips)} credits: {len(good)} over-credits fixed, "
                  f"{len(bad)} correct credits destroyed", ""]
        if bad:
            lines += ["  Correct credits destroyed (recall damage):"]
            lines += [f"  - {t} · {c}" for t, c in bad]
            lines += [""]
    onlyh = sorted(set(human) - set(judged))
    onlyj = sorted(set(judged) - set(human))
    if onlyh:
        lines.append(f"- WARNING: {len(onlyh)} scored decision(s) with no judge output")
    if onlyj:
        lines.append(f"- WARNING: {len(onlyj)} judged decision(s) with no human score")

    lines += ["", "## Per-criterion", "",
              "| criterion | n | agree | human met | judge met |", "|---|---|---|---|---|"]
    for c in criteria_in_order():
        cid = c["id"]
        ks = [k for k in scored if k[1] == cid]
        if not ks:
            continue
        ag = sum(bin_(human[k]) == bin_(judged[k]["pred"]) for k in ks)
        lines.append(f"| {cid} | {len(ks)} | {ag}/{len(ks)} | "
                     f"{sum(human[k] == 'met' for k in ks)} | "
                     f"{sum(judged[k]['pred'] == 'met' for k in ks)} |")

    lines += ["", "## Disagreements (binary)", ""]
    if not dis:
        lines.append("None.")
    for k in dis:
        r = judged[k]
        direction = ("judge over-credits" if bin_(judged[k]["pred"]) == "met"
                     else "judge under-credits")
        vnote = ""
        if verified and r["pred"] == "met":
            vnote = (" — verifier REJECTED (fixed)" if r["final"] == "missed"
                     else " — verifier confirmed (still wrong)")
        lines += [f"### {k[0]} · {k[1]} — human: {human[k]}, judge: {r['pred']} "
                  f"({direction}){vnote}",
                  f"- judge evidence: {r['evidence'] or '(none)'}",
                  f"- judge raw: `{(r['raw'] or '').strip()[:200]}`", ""]
    if na:
        lines += ["## Human-na rows (excluded)", ""]
        lines += [f"- {t} · {c} (judge said {judged[(t, c)]['pred']})" for t, c in na]
    if unscored:
        lines += ["", f"## Unscored rows ({len(unscored)}) — sheet still has `?`", ""]
        lines += [f"- {t} · {c}" for t, c in unscored]

    out = base / ("REPORT.md" if jdir == "judge" else f"REPORT-{jdir.split('-', 1)[1]}.md")
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:12]))
    print(f"\nfull report -> {out}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["sheet", "judge", "verify", "report"])
    ap.add_argument("--dir", default=str(HERE / "calibration"),
                    help="calibration base directory (default: ./calibration)")
    ap.add_argument("--model", default=DEFAULT_MODEL, help="judge model id")
    ap.add_argument("--adapter-path", help="LoRA adapter directory to load on top of --model")
    ap.add_argument("--tag", help="label for this configuration; judge/verify write to "
                                  "judge-<tag>/ and report reads it + writes REPORT-<tag>.md, "
                                  "so adapter runs never clobber the stock baseline")
    ap.add_argument("--think", action="store_true",
                    help="enable reasoning mode (default off — matches the shipped config)")
    args = ap.parse_args()
    base = Path(args.dir)
    (base / "transcripts").mkdir(parents=True, exist_ok=True)
    if args.adapter_path and not args.tag:
        ap.error("--adapter-path requires --tag (so the stock baseline is not overwritten)")
    jdir = "judge" + (f"-{args.tag}" if args.tag else "")
    if args.cmd == "sheet":
        cmd_sheet(base)
    elif args.cmd == "judge":
        cmd_judge(base, args.model, not args.think, jdir, args.adapter_path)
    elif args.cmd == "verify":
        cmd_verify(base, args.model, not args.think, jdir, args.adapter_path)
    else:
        cmd_report(base, jdir)


if __name__ == "__main__":
    main()
