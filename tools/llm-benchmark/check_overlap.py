#!/usr/bin/env python3
"""Contamination gate: is the fine-tune data disjoint from the eval sets?

Checks data/finetune_v4/ against the three evaluation sets (240-set snippet
library, 48-case realistic screen, calibration gold transcripts) two ways:

  exact   — normalized full-line matches between training doctor lines and any
            eval text line. MUST be zero; any hit fails the gate (exit 1).
  5-gram  — shared normalized 5-word sequences. Cannot be zero for same-domain
            clinical dialogue (there are only so many ways to say "come back
            if it gets worse"), so it is judged against the measured baseline:
            the eval sets share ~21 5-grams with EACH OTHER despite disjoint
            provenance. Training overlap far above that baseline fails.

Run standalone or as the pre-training gate in run_v4_train.sh.
History: the first run of this check (2026-09-03) caught 9 pool lines that had
been adapted from the calibration transcripts — real leakage into the decision
set that an assurance would have missed. They were purged.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).parent
NGRAM_LIMIT = 60  # ~3x the eval-vs-eval baseline of ~21


def norm(s):
    return " ".join("".join(c if c.isalnum() else " " for c in s.lower()).split())


def ngrams(text, n=5):
    w = norm(text).split()
    return {" ".join(w[i:i + n]) for i in range(len(w) - n + 1)}


def main():
    v4_lines = set()
    for fn in ("train", "valid"):
        f = HERE / "data" / "finetune_v4" / f"{fn}.jsonl"
        if not f.exists():
            print(f"missing {f} — run gen_finetune_v4.py first")
            sys.exit(2)
        for line in f.read_text().splitlines():
            u = json.loads(line)["messages"][0]["content"]
            if "TRANSCRIPT:" not in u:
                continue
            for tl in u[u.index("TRANSCRIPT:"):].splitlines():
                if tl.startswith("Doctor: "):
                    v4_lines.add(tl[8:])
    v4_ng = set()
    for l in v4_lines:
        v4_ng |= ngrams(l)
    v4_norm = {norm(l) for l in v4_lines}

    sn = json.loads((HERE / "criterion_snippets.json").read_text())
    evals = {
        "240-set snippets": "\n".join(d["doctor"] + "\n" + d["patient"]
                                      for k, d in sn.items() if k != "_comment"),
        "48-case realistic": "\n".join(c["flat"] for c in
                                       json.loads((HERE / "realistic_cases.json").read_text())),
        "calibration gold": "\n".join(p.read_text() for p in
                                      (HERE / "calibration" / "transcripts").glob("*.txt")
                                      if not p.stem.startswith("_")),
    }

    failed = False
    for name, text in evals.items():
        exact = v4_norm & {norm(x) for x in text.splitlines() if x.strip()}
        shared = v4_ng & ngrams(text)
        status = "OK"
        if exact:
            status, failed = "FAIL (exact match)", True
        elif len(shared) > NGRAM_LIMIT:
            status, failed = f"FAIL (>{NGRAM_LIMIT} shared 5-grams)", True
        print(f"{name:<20} exact: {len(exact)}   shared 5-grams: {len(shared):>3}   {status}")
        for e in sorted(exact)[:5]:
            print(f"    EXACT: '{e}'")

    base = ngrams(evals["48-case realistic"]) & ngrams(evals["calibration gold"])
    print(f"\n(baseline: the two disjoint-provenance eval sets share {len(base)} "
          f"5-grams with each other — same-domain phrase-stock)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
