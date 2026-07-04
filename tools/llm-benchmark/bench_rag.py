#!/usr/bin/env python3
"""Full-transcript vs RAG (embedding-retrieval) scoring comparison.

--mode full : score each criterion against the WHOLE transcript (baseline)
--mode rag  : embed transcript turns once, retrieve the top-k most relevant
              turns per criterion, and score against ONLY those excerpts.

Reports accuracy/over-score/recall (same as the other benches) PLUS speed:
avg prompt tokens per call and avg seconds per call — the token reduction is
what maps to on-device time/heat for 15-minute consultations.

Retrieval uses sentence-transformers (all-MiniLM-L6-v2). Verbose per-call output.
"""
import argparse, json, time
from pathlib import Path

from mlx_lm import load, generate

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
RESULTS = HERE / "results"
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"


def load_cases(which: str, limit: int):
    if which == "realistic":
        cases = json.loads((HERE / "realistic_cases.json").read_text())
    else:
        cases = json.loads((HERE / "data" / "scoring.json").read_text())
    return cases[:limit] if limit else cases


def turns_of(case) -> list[str]:
    """Transcript as 'Speaker: text' lines."""
    return [l for l in case["flat"].splitlines() if l.strip()]


class Retriever:
    """Embeds turns once per case; returns top-k turns per criterion query,
    in original (chronological) order."""

    def __init__(self):
        from sentence_transformers import SentenceTransformer
        self.model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")

    def top_k(self, turns: list[str], query: str, k: int) -> list[str]:
        import numpy as np
        te = self.model.encode(turns, normalize_embeddings=True)
        qe = self.model.encode([query], normalize_embeddings=True)[0]
        sims = te @ qe
        idx = sorted(np.argsort(-sims)[:k])   # top-k, back in chronological order
        return [turns[i] for i in idx]


def criterion_query(c: dict) -> str:
    parts = [c["prompt"]]
    if c.get("whatGoodLooksLike"):
        parts.append(c["whatGoodLooksLike"])
    if c.get("requiredElements"):
        parts.append("; ".join(c["requiredElements"]))
    return " ".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/Qwen2.5-7B-Instruct-4bit")
    ap.add_argument("--mode", choices=["full", "rag"], required=True)
    ap.add_argument("--data", choices=["realistic", "snippets"], default="realistic")
    ap.add_argument("--k", type=int, default=6, help="turns to retrieve (rag mode)")
    ap.add_argument("--limit", type=int, default=0, help="only first N cases")
    args = ap.parse_args()

    criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
    cases = load_cases(args.data, args.limit)

    retriever = Retriever() if args.mode == "rag" else None

    print(f"Loading {args.model} …")
    model, tokenizer = load(args.model)

    def run_llm(prompt: str) -> tuple[str, int]:
        messages = [{"role": "user", "content": prompt}]
        text = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        n_tokens = len(text) if isinstance(text, list) else len(tokenizer.encode(text))
        return generate(model, tokenizer, prompt=text, max_tokens=180, verbose=False), n_tokens

    total = sum(len(c["labels"]) for c in cases)
    print(f"mode={args.mode} data={args.data} k={args.k}  cases={len(cases)}  calls={total}\n")

    rows, done = [], 0
    t0 = time.time()
    for case in cases:
        turns = turns_of(case)
        for cid, truth in case["labels"].items():
            done += 1
            crit = criteria[cid]
            if retriever:
                excerpt = "\n".join(retriever.top_k(turns, criterion_query(crit), args.k))
                context = excerpt
            else:
                context = case["flat"]
            ti = time.time()
            raw, n_tok = run_llm(build_prompt(crit, context))
            dt = time.time() - ti
            pred, _ = parse_criterion(raw, context)
            pred_met, truth_met = (pred == "met"), (truth == "met")
            ok = (pred_met == truth_met)
            mark = "OK " if ok else ("OVER" if pred_met else "MISS")
            print(f"  [{done:>3}/{total}] {case['id'][:12]:<12} {cid:<19} "
                  f"truth={truth:<6} pred={pred:<7} {mark} {n_tok:>5} tok  ({dt:4.1f}s)")
            rows.append({"case": case["id"], "criterion": cid, "truth": truth,
                         "pred": pred, "correct": ok, "tokens": n_tok, "seconds": dt})

    RESULTS.mkdir(exist_ok=True)
    tag = f"{args.mode}_{args.data}"
    (RESULTS / f"rag_{tag}.json").write_text(json.dumps(rows, indent=2))
    summarize(args, rows, time.time() - t0)


def summarize(args, rows, dt):
    n = len(rows)
    correct = sum(r["correct"] for r in rows)
    missed = [r for r in rows if r["truth"] == "missed"]
    met = [r for r in rows if r["truth"] == "met"]
    over = sum(r["pred"] == "met" for r in missed)
    recall = sum(r["pred"] == "met" for r in met)
    avg_tok = sum(r["tokens"] for r in rows) / n
    avg_sec = sum(r["seconds"] for r in rows) / n
    print(f"\n========== {args.mode.upper()} / {args.data} ==========")
    print(f"accuracy:     {correct/n*100:5.1f}%   ({correct}/{n})")
    print(f"over-score:   {over/max(1,len(missed))*100:5.1f}%   ({over}/{len(missed)})")
    print(f"recall(met):  {recall/max(1,len(met))*100:5.1f}%   ({recall}/{len(met)})")
    print(f"avg prompt:   {avg_tok:6.0f} tokens/call   ← maps to on-device time+heat")
    print(f"avg latency:  {avg_sec:6.1f} s/call   (total {dt:.0f}s)")

    # Per-criterion accuracy — shows which criteria suffer under retrieval.
    print("\nper-criterion accuracy:")
    by = {}
    for r in rows:
        by.setdefault(r["criterion"], []).append(r["correct"])
    for cid, oks in sorted(by.items()):
        print(f"  {cid:<20} {sum(oks)}/{len(oks)}")


if __name__ == "__main__":
    main()
