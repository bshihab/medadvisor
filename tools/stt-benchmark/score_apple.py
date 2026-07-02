#!/usr/bin/env python3
"""Scores Apple's transcripts (results/apple_raw.json, from AppleTranscribe.swift)
against the ground-truth dataset, using the same WER metric as bench_stt.py."""
import json
from pathlib import Path

from bench_stt import wer, bucket

HERE = Path(__file__).parent
DATA = HERE / "data"
RESULTS = HERE / "results"


def main():
    raw = json.loads((RESULTS / "apple_raw.json").read_text())
    dataset = {d["id"]: d for d in json.loads((DATA / "dataset.json").read_text())}

    rows = []
    for sid, hyp in raw.items():
        conv = dataset.get(sid)
        if not conv:
            continue
        rows.append({"id": sid, "wer": wer(conv["flat"], hyp),
                     "bucket": bucket(conv["n_turns"])})

    if not rows:
        print("No matching transcripts found.")
        return
    overall = sum(r["wer"] for r in rows) / len(rows)
    print("===== APPLE STT WER (lower is better) =====")
    print(f"  overall: {overall*100:.1f}%  (n={len(rows)})")
    for b in ["short (<=10 turns)", "medium (11-24)", "long (25+)"]:
        br = [r["wer"] for r in rows if r["bucket"] == b]
        if br:
            print(f"  {b:<22} {sum(br)/len(br)*100:.1f}%")


if __name__ == "__main__":
    main()
