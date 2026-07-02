#!/usr/bin/env python3
"""Whisper vs Parakeet WER benchmark over the generated dataset.

Each conversation is transcribed `--runs` times per engine (default 3 → 300
runs/engine for 100 convos). Reports mean WER overall and by conversation
length bucket. Writes results/stt.json.
"""
import argparse, json, re, time
from pathlib import Path

import jiwer

from engines import available_engines

HERE = Path(__file__).parent
DATA = HERE / "data"
RESULTS = HERE / "results"

_PUNCT = re.compile(r"[^a-z0-9\s]")
_WS = re.compile(r"\s+")


def _norm(s: str) -> str:
    """Lowercase, drop punctuation, collapse whitespace — applied to both sides
    so scoring is version-independent (jiwer 4.x dropped transform kwargs)."""
    s = _PUNCT.sub(" ", s.lower())
    return _WS.sub(" ", s).strip()


def wer(ref: str, hyp: str) -> float:
    ref_n, hyp_n = _norm(ref), _norm(hyp)
    if not ref_n:
        return 0.0
    if not hyp_n:
        return 1.0
    return jiwer.wer(ref_n, hyp_n)


def bucket(n_turns: int) -> str:
    if n_turns <= 10:
        return "short (<=10 turns)"
    if n_turns <= 24:
        return "medium (11-24)"
    return "long (25+)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    args = ap.parse_args()

    dataset = json.loads((DATA / "dataset.json").read_text())
    engines = available_engines()
    if not engines:
        print("No STT engines available. `pip install mlx-whisper parakeet-mlx`.")
        return
    print("Engines:", ", ".join(e.name for e in engines))

    RESULTS.mkdir(exist_ok=True)
    results = {e.name: [] for e in engines}

    for e in engines:
        print(f"\n=== {e.name} ===")
        t0 = time.time()
        for conv in dataset:
            wav = str(DATA / "audio" / f"{conv['id']}.wav")
            for r in range(args.runs):
                try:
                    hyp = e.transcribe(wav)
                    score = wer(conv["flat"], hyp)
                except Exception as ex:
                    print(f"  {conv['id']} run{r} FAILED: {ex}")
                    continue
                results[e.name].append(
                    {"id": conv["id"], "run": r, "wer": score,
                     "n_turns": conv["n_turns"], "bucket": bucket(conv["n_turns"])})
        dt = time.time() - t0
        print(f"  done in {dt:.0f}s ({len(results[e.name])} runs)")

    (RESULTS / "stt.json").write_text(json.dumps(results, indent=2))
    print_summary(results)


def print_summary(results):
    print("\n================ WER SUMMARY (lower is better) ================")
    buckets = ["short (<=10 turns)", "medium (11-24)", "long (25+)"]
    header = f"{'engine':<12}{'overall':>10}" + "".join(f"{b:>22}" for b in buckets)
    print(header)
    for name, rows in results.items():
        if not rows:
            print(f"{name:<12}{'n/a':>10}")
            continue
        overall = sum(r["wer"] for r in rows) / len(rows)
        line = f"{name:<12}{overall*100:>9.1f}%"
        for b in buckets:
            br = [r["wer"] for r in rows if r["bucket"] == b]
            line += f"{(sum(br)/len(br)*100 if br else 0):>21.1f}%"
        print(line)
    print("Results written to results/stt.json")


if __name__ == "__main__":
    main()
