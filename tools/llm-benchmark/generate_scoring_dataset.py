#!/usr/bin/env python3
"""Generate labeled consultation transcripts for the scoring benchmark.

For each transcript, each rubric criterion is randomly labeled MET or MISSED.
If met, the Doctor snippet that satisfies it is included; if missed, it's
omitted entirely. So we know the ground-truth met/missed for every criterion.

Writes data/scoring.json: [{id, turns, flat, labels:{criterionId: met|missed}}]
"""
import argparse, json, random
from pathlib import Path

HERE = Path(__file__).parent
DATA = HERE / "data"
# The app's rubric lives in the repo; load it so the test uses real criteria.
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=15)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--met-prob", type=float, default=0.5,
                    help="probability each criterion is included (met)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    rubric = json.loads(RUBRIC.read_text())
    criteria = rubric["criteria"]  # in consultation order
    snippets = json.loads((HERE / "criterion_snippets.json").read_text())

    DATA.mkdir(exist_ok=True)
    dataset = []
    for i in range(args.n):
        sid = f"case{i:03d}"
        turns, labels = [], {}
        turns.append({"speaker": "Patient",
                      "text": "Hi doctor, I've come in because I've not been feeling right."})
        for c in criteria:
            cid = c["id"]
            snip = snippets.get(cid)
            met = snip is not None and rng.random() < args.met_prob
            labels[cid] = "met" if met else "missed"
            if met:
                turns.append({"speaker": "Doctor", "text": snip["doctor"]})
                turns.append({"speaker": "Patient", "text": snip["patient"]})
        flat = "\n".join(f"{t['speaker']}: {t['text']}" for t in turns)
        dataset.append({"id": sid, "turns": turns, "flat": flat, "labels": labels})

    (DATA / "scoring.json").write_text(json.dumps(dataset, indent=2))
    n_met = sum(v == "met" for d in dataset for v in d["labels"].values())
    n_tot = sum(len(d["labels"]) for d in dataset)
    print(f"Wrote {len(dataset)} cases to {DATA/'scoring.json'}")
    print(f"Criterion decisions: {n_tot}  (met={n_met}, missed={n_tot-n_met})")


if __name__ == "__main__":
    main()
