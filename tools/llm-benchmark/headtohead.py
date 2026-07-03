#!/usr/bin/env python3
"""Head-to-head: FluidAudio diarization vs LLM-only attribution on the SAME real
audio, scored turn-by-turn (fair — both label the identical app-produced turns).

Input: a JSON file `cases/<name>.json`:
  [
    {"text": "Good morning, I'm Dr...", "fluidaudio": "Doctor", "truth": "Doctor"},
    {"text": "Hi, thanks.",            "fluidaudio": "Patient", "truth": "Patient"},
    ...
  ]
where `fluidaudio` = the label the APP produced (from FluidAudio diarization),
and `truth` = who actually said it (known from the read script).

We score:
  - FluidAudio: agreement of its labels with truth (best-of-2 mapping = separation).
  - LLM: feed the ordered turns UNLABELED, ask the model to label each, score the same way.
"""
import argparse, json, re
from pathlib import Path

from mlx_lm import load, generate

HERE = Path(__file__).parent


def best_accuracy(pred, truth):
    """Turn-level accuracy under the better of the two Doctor/Patient mappings
    (separation) and as-is (role)."""
    ident = sum(p == t for p, t in zip(pred, truth))
    swap = {"Doctor": "Patient", "Patient": "Doctor"}
    swapped = sum(swap.get(p, p) == t for p, t in zip(pred, truth))
    n = len(truth)
    return max(ident, swapped) / n, ident / n   # separation, role


def llm_labels(model, tokenizer, turns):
    numbered = "\n".join(f"{i+1}. {t['text']}" for i, t in enumerate(turns))
    prompt = (
        "Below is a doctor-patient consultation, one utterance per numbered line, "
        "with NO speaker labels. For EACH numbered line, say who spoke it — Doctor "
        "or Patient. Output one line per utterance in the form `N: Doctor` or "
        "`N: Patient`, nothing else.\n\n" + numbered
    )
    messages = [{"role": "user", "content": prompt}]
    text = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    out = generate(model, tokenizer, prompt=text, max_tokens=1024, verbose=False)

    labels = ["Patient"] * len(turns)   # default
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s*[:.)]\s*(doctor|patient)", line.strip().lower())
        if m:
            idx = int(m.group(1)) - 1
            if 0 <= idx < len(turns):
                labels[idx] = "Doctor" if m.group(2) == "doctor" else "Patient"
    return labels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("case", help="path to a cases/*.json file")
    ap.add_argument("--model", default="mlx-community/Qwen2.5-7B-Instruct-4bit")
    args = ap.parse_args()

    turns = json.loads(Path(args.case).read_text())
    truth = [t["truth"] for t in turns]
    fluid = [t["fluidaudio"] for t in turns]

    print(f"Loading {args.model} …")
    model, tokenizer = load(args.model)
    llm = llm_labels(model, tokenizer, turns)

    f_sep, f_role = best_accuracy(fluid, truth)
    l_sep, l_role = best_accuracy(llm, truth)

    print(f"\n=== HEAD-TO-HEAD ({Path(args.case).stem}, {len(turns)} turns) ===")
    print(f"{'':12}{'separation':>12}{'role':>10}")
    print(f"{'FluidAudio':12}{f_sep*100:>11.1f}%{f_role*100:>9.1f}%")
    print(f"{'LLM (Qwen)':12}{l_sep*100:>11.1f}%{l_role*100:>9.1f}%")
    print("\nper-turn (truth | fluidaudio | llm):")
    for t, tr, f, l in zip(turns, truth, fluid, llm):
        flag = "" if (f == tr and l == tr) else "  <-- disagreement"
        print(f"  {tr:8} | {f:8} | {l:8}{flag}   {t['text'][:50]}")


if __name__ == "__main__":
    main()
