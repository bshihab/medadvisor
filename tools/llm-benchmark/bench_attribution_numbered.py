#!/usr/bin/env python3
"""Speaker attribution as the APP actually does it: numbered utterances in,
"N: D" / "N: P" out (PromptBuilder.speakerAttributionPrompt).

Why not bench_attribution.py: that one flattens the transcript WITHOUT labels and
asks the model to reconstruct it — an older design the app moved away from
because whole-transcript reconstruction caused phase-slips. The shipped path
gives the model FIXED utterance boundaries and asks only for a role per line.
Testing a model trained on the numbered format against the reconstruction format
would measure nothing.

Metrics (per utterance, which is the unit the app consumes):
  role accuracy       — as labeled; also got which speaker is the clinician
  separation accuracy — best of the two D/P mappings; did it at least split them
  missing             — utterances the model never labeled (the merger inherits
                        the previous speaker, so these degrade quietly)

Usage:
  python bench_attribution_numbered.py --model mlx-community/Qwen2.5-3B-Instruct-4bit
  python bench_attribution_numbered.py --model ... --adapter adapters/qwen3b
"""
import argparse, json, re, time
from pathlib import Path

from mlx_lm import load, generate

from app_scoring import build_attribution_prompt

HERE = Path(__file__).parent
DATA = HERE / "data"
RESULTS = HERE / "results"


def parse_labels(raw: str, count: int):
    """Port of PromptBuilder.parseAttribution: tolerate markdown/punctuation,
    take the first D/P after the number. Unlabeled lines stay None."""
    roles = [None] * count
    for line in raw.splitlines():
        m = re.search(r"\d+", line)
        if not m:
            continue
        n = int(m.group())
        if not (1 <= n <= count):
            continue
        rest = line[m.end():].lower()
        d, p = rest.find("d"), rest.find("p")
        if d == -1 and p == -1:
            continue
        if d == -1:
            roles[n - 1] = "Patient"
        elif p == -1:
            roles[n - 1] = "Doctor"
        else:
            roles[n - 1] = "Doctor" if d < p else "Patient"
    return roles


def score_case(turns, raw):
    truth = [t["speaker"] for t in turns]
    got = parse_labels(raw, len(turns))
    labeled = [(g, t) for g, t in zip(got, truth) if g is not None]
    missing = len(turns) - len(labeled)
    if not labeled:
        return 0.0, 0.0, missing
    role = sum(g == t for g, t in labeled) / len(turns)
    # separation: also credit the consistently-inverted mapping
    inverted = sum((g == "Doctor") != (t == "Doctor") for g, t in labeled) / len(turns)
    return max(role, inverted), role, missing


def make_chat_text(tokenizer, prompt, no_think):
    """Qwen3/3.5 are reasoning models: by default they emit a long "Thinking
    Process:" block and blow the app's tight token budget before answering
    (measured: Qwen3.5-4B labeled 1 of 21 utterances). Prefer the template's
    enable_thinking=False; fall back to Qwen's /no_think soft switch if the
    template does not accept the kwarg."""
    messages = [{"role": "user", "content": prompt}]
    if no_think:
        try:
            return tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, enable_thinking=False)
        except TypeError:
            messages = [{"role": "user", "content": prompt + "\n/no_think"}]
    return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--adapter", help="path to a trained LoRA adapter dir")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--no-think", action="store_true",
                    help="disable reasoning mode (Qwen3/3.5)")
    ap.add_argument("--realistic", action="store_true",
                    help="use the HAND-WRITTEN cases instead of the synthetic set — the\n                          generalization test: different provenance AND structure from training")
    args = ap.parse_args()

    src = "attribution_realistic.json" if args.realistic else "scoring.json"
    dataset = json.loads((DATA / src).read_text())
    print(f"dataset: {src}")
    if args.limit:
        dataset = dataset[:args.limit]

    print(f"Loading {args.model}" + (f" + {args.adapter}" if args.adapter else "") + " …")
    model, tokenizer = load(args.model, adapter_path=args.adapter)

    def run_llm(prompt, max_tokens):
        text = make_chat_text(tokenizer, prompt, args.no_think)
        return generate(model, tokenizer, prompt=text, max_tokens=max_tokens, verbose=False)

    rows = []
    for i, case in enumerate(dataset, 1):
        turns = case["turns"]
        utts = [t["text"] for t in turns]
        ti = time.time()
        # Same budget the app uses: utterances * 5 + 32 (EncounterProcessor:129)
        raw = run_llm(build_attribution_prompt(utts), len(utts) * 5 + 32)
        sep, role, missing = score_case(turns, raw)
        rows.append({"case": case["id"], "utterances": len(turns), "separation": sep,
                     "role": role, "missing": missing, "raw": raw[:300]})
        print(f"  [{i:>3}/{len(dataset)}] {case['id']}: role={role*100:5.1f}%  "
              f"separation={sep*100:5.1f}%  missing={missing:>2}/{len(turns)}  "
              f"({time.time()-ti:4.1f}s)")

    n = len(rows)
    tot_utt = sum(r["utterances"] for r in rows)
    print("\n============ NUMBERED ATTRIBUTION SUMMARY ============")
    print(f"model:        {args.model}" + (f"  + {args.adapter}" if args.adapter else ""))
    print(f"cases:        {n}   utterances: {tot_utt}")
    print(f"role acc:     {sum(r['role'] for r in rows)/n*100:5.1f}%   "
          "(correct D/P as labeled — what the app consumes)")
    print(f"separation:   {sum(r['separation'] for r in rows)/n*100:5.1f}%   "
          "(credits a consistently inverted mapping)")
    print(f"unlabeled:    {sum(r['missing'] for r in rows)}/{tot_utt} utterances "
          "(these silently inherit the previous speaker)")
    print("baseline for reference — 7B on the OLD reconstruction prompt: "
          "separation 73.6% / role 68.1%")

    RESULTS.mkdir(exist_ok=True)
    safe = args.model.replace("/", "__")
    if args.adapter:
        safe += "__lora-" + Path(args.adapter).name
    if args.no_think:
        safe += "__nothink"
    if args.realistic:
        safe += "__realistic"
    out = RESULTS / f"attribution_numbered_{safe}.json"
    out.write_text(json.dumps(rows, indent=2))
    print(f"rows -> {out}")


if __name__ == "__main__":
    main()
