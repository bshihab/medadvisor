#!/usr/bin/env python3
"""Speaker-attribution benchmark: can the LLM split Doctor vs Patient from a
FLAT (label-less) transcript? Answers "could we drop diarization?".

Verbose: prints each case's separation/role accuracy live.

  separation accuracy = best of the two Doctor/Patient label mappings
  role accuracy       = as-labeled (also got which speaker is the Doctor)
"""
import argparse, difflib, json, re, time
from pathlib import Path

from mlx_lm import load, generate

HERE = Path(__file__).parent
DATA = HERE / "data"
RESULTS = HERE / "results"

PROMPT = """Below is a raw transcript of a two-person doctor-patient consultation. \
It has NO speaker labels. Reconstruct the conversation, labeling every utterance \
as either "Doctor:" or "Patient:". Keep the wording exactly; only add the labels. \
Output only the labeled lines, one utterance per line.

TRANSCRIPT:
{flat}
"""


def norm_words(s):
    return re.findall(r"[a-z0-9]+", s.lower())


def gt_word_roles(turns):
    return [(t["speaker"], w) for t in turns for w in norm_words(t["text"])]


def parse_hyp(text):
    out = []
    for line in text.splitlines():
        low = line.strip().lower()
        if low.startswith("doctor"):
            role, rest = "Doctor", line.split(":", 1)[-1]
        elif low.startswith("patient"):
            role, rest = "Patient", line.split(":", 1)[-1]
        else:
            continue
        out += [(role, w) for w in norm_words(rest)]
    return out


def score(turns, hyp_text):
    gt = gt_word_roles(turns)
    hyp = parse_hyp(hyp_text)
    if not gt or not hyp:
        return 0.0, 0.0
    sm = difflib.SequenceMatcher(a=[w for _, w in gt], b=[w for _, w in hyp], autojunk=False)
    ident = swapped = 0
    for a, b, size in sm.get_matching_blocks():
        for k in range(size):
            g, h = gt[a + k][0], hyp[b + k][0]
            if g == h:
                ident += 1
            if g == ("Doctor" if h == "Patient" else "Patient"):
                swapped += 1
    n = len(gt)
    return max(ident, swapped) / n, ident / n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    dataset = json.loads((DATA / "scoring.json").read_text())
    if args.limit:
        dataset = dataset[:args.limit]

    print(f"Loading {args.model} …")
    model, tokenizer = load(args.model)

    def run_llm(prompt):
        messages = [{"role": "user", "content": prompt}]
        text = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        return generate(model, tokenizer, prompt=text, max_tokens=1024, verbose=False)

    print(f"Model: {args.model}   cases: {len(dataset)}\n")
    rows = []
    for i, case in enumerate(dataset, 1):
        # Flatten WITHOUT speaker labels.
        flat = " ".join(t["text"] for t in case["turns"])
        ti = time.time()
        sep, role = score(case["turns"], run_llm(PROMPT.format(flat=flat)))
        rows.append({"case": case["id"], "separation": sep, "role": role})
        print(f"  [{i:>3}/{len(dataset)}] {case['id']}: "
              f"separation={sep*100:5.1f}%  role={role*100:5.1f}%  ({time.time()-ti:4.1f}s)")

    RESULTS.mkdir(exist_ok=True)
    safe = args.model.replace("/", "__")
    (RESULTS / f"attribution_{safe}.json").write_text(json.dumps(rows, indent=2))
    sep = sum(r["separation"] for r in rows) / len(rows)
    rol = sum(r["role"] for r in rows) / len(rows)
    print("\n================ ATTRIBUTION SUMMARY ================")
    print(f"model:      {args.model}")
    print(f"separation: {sep*100:5.1f}%   (split the two voices)")
    print(f"role:       {rol*100:5.1f}%   (also got which is the Doctor)")


if __name__ == "__main__":
    main()
