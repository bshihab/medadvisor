#!/usr/bin/env python3
"""LLM-only speaker detection test.

Feeds each conversation's FLAT transcript (no speaker labels, no timestamps) to
MedGemma and asks it to reconstruct Doctor/Patient turns — i.e. the "can the LLM
do who-said-what without diarization?" experiment.

Metrics (word-level, aligned to ground truth via difflib):
  separation accuracy = best of the two Doctor/Patient label mappings
  role accuracy       = as-labeled (also got which is the Doctor right)

Uses MedGemma 4B via mlx-lm (prebuilt for Apple Silicon; same model family as
the app, which runs the GGUF via llama.cpp — fine for measuring attribution).
"""
import argparse, difflib, json, re
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


def norm_words(s: str):
    return re.findall(r"[a-z0-9]+", s.lower())


def gt_word_roles(turns):
    return [(t["speaker"], w) for t in turns for w in norm_words(t["text"])]


def parse_hyp(text: str):
    """Parse 'Doctor:/Patient:' labeled lines into (role, word) pairs."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        low = line.lower()
        if low.startswith("doctor"):
            role, rest = "Doctor", line.split(":", 1)[-1]
        elif low.startswith("patient"):
            role, rest = "Patient", line.split(":", 1)[-1]
        else:
            continue
        for w in norm_words(rest):
            out.append((role, w))
    return out


def score(turns, hyp_text):
    gt = gt_word_roles(turns)
    hyp = parse_hyp(hyp_text)
    if not gt or not hyp:
        return 0.0, 0.0
    sm = difflib.SequenceMatcher(a=[w for _, w in gt], b=[w for _, w in hyp],
                                 autojunk=False)
    ident = swapped = 0
    for a, b, size in sm.get_matching_blocks():
        for k in range(size):
            g = gt[a + k][0]
            h = hyp[b + k][0]
            if g == h:
                ident += 1
            if g == ("Doctor" if h == "Patient" else "Patient"):
                swapped += 1
    n = len(gt)
    return max(ident, swapped) / n, ident / n   # separation, role


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/medgemma-4b-it-4bit",
                    help="MLX model id (auto-downloads). If this 404s, search "
                         "huggingface.co/mlx-community for a medgemma-4b-it build.")
    ap.add_argument("--runs", type=int, default=1,
                    help="temp=0 is deterministic, so 1 is usually enough")
    args = ap.parse_args()

    dataset = json.loads((DATA / "dataset.json").read_text())
    model, tokenizer = load(args.model)

    def run_llm(prompt: str) -> str:
        messages = [{"role": "user", "content": prompt}]
        text = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        return generate(model, tokenizer, prompt=text, max_tokens=1024, verbose=False)

    RESULTS.mkdir(exist_ok=True)
    rows = []
    for conv in dataset:
        for r in range(args.runs):
            hyp = run_llm(PROMPT.format(flat=conv["flat"]))
            sep, role = score(conv["turns"], hyp)
            rows.append({"id": conv["id"], "run": r, "n_turns": conv["n_turns"],
                         "separation": sep, "role": role})
        if len(rows) % 10 == 0:
            print(f"  {len(rows)} done…")

    (RESULTS / "attribution.json").write_text(json.dumps(rows, indent=2))
    summarize(rows)


def summarize(rows):
    def bucket(n):
        return "short (<=10)" if n <= 10 else "medium (11-24)" if n <= 24 else "long (25+)"
    print("\n===== LLM-ONLY SPEAKER ATTRIBUTION (higher is better) =====")
    for label in ["short (<=10)", "medium (11-24)", "long (25+)", "ALL"]:
        sel = rows if label == "ALL" else [r for r in rows if bucket(r["n_turns"]) == label]
        if not sel:
            continue
        sep = sum(r["separation"] for r in sel) / len(sel)
        role = sum(r["role"] for r in sel) / len(sel)
        print(f"  {label:<16} separation={sep*100:5.1f}%   role={role*100:5.1f}%   (n={len(sel)})")
    print("Results written to results/attribution.json")


if __name__ == "__main__":
    main()
