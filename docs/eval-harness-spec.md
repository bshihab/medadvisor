# Eval Harness Spec (M3)

Purpose: decide which model ships by measuring **agreement between the model's scoring and the director's scoring** on the same transcripts. The model that best matches the director — not the one with "med" in its name — wins.

## Inputs

1. **Rubrics** — `rubrics/*.json` (validated against `rubric.schema.json`), signed off by the director.
2. **Gold set** — the director's scores on real/role-played transcripts (format below).
3. **Models under test** — Gemma 3n, MedGemma 4B, Qwen2.5-7B (extensible).

## Gold-set format (`eval/gold/<encounter-type>.json`)

```json
{
  "rubricId": "spikes-breaking-bad-news",
  "rubricVersion": "0.1.0-draft",
  "records": [
    {
      "transcriptId": "bbn-001",
      "encounterType": "Breaking bad news",
      "transcript": "…full text, OR a path to a local file…",
      "directorScores": {
        "setting_privacy":        { "met": true,  "evidence": "Is it alright if we talk here…", "comment": "" },
        "perception_assess":      { "met": false, "evidence": null, "comment": "Went straight to results." },
        "empathy_named_emotion":  { "met": true,  "evidence": "I can see this is a shock." }
      },
      "directorOverall": 0.62
    }
  ]
}
```

- `met` is the director's ground-truth yes/no per criterion (or a number for scaled items).
- `evidence` is the quote the director anchored on — used later to check whether the model cited the *same* moment.
- Keep a **held-out split** (≥30% of records) that no prompt tuning ever sees — M7 reports on this set only.

## What the harness does

For each (model × transcript): run the real pipeline (redact → rubric scoring) and capture, per criterion, the model's `met` + cited `evidence`. Then compare to `directorScores`.

## Metrics

Per criterion, across the gold set:
- **Agreement / accuracy** — % of records where model `met` == director `met`.
- **Cohen's κ** — agreement corrected for chance (the honest headline number).
- **Precision / recall** — recall on "met=true" matters: catch what the student actually did; recall on "met=false" matters for not hallucinating credit.

Per record:
- **Overall-score correlation** — Spearman ρ between model overall and `directorOverall`.

Evidence quality (spot-check, can be sampled not exhaustive):
- **Evidence overlap** — when model and director both say "met", do they cite the same region of the transcript? (Guards against right-answer-wrong-reason.)

Safety:
- **Critical-fail recall** — on `criticalFail` criteria (e.g. missed safety-netting), the false-negative rate must be ~0. Missing a safety failure is the worst error; report it separately and weight it heavily.

## The bar (set with the director in M1, before running)

A model passes if, on the held-out set:
- per-criterion **κ ≥ the human inter-rater κ** measured in M1 (you can't beat the humans, but you should match them), **and**
- overall-score **ρ ≥ [agreed]**, **and**
- **critical-fail false-negative rate ≈ 0**.

## Output

A reproducible table — rerun the script, get the same numbers:

| Model | Mean κ | Overall ρ | Critical-fail FN | Verdict |
|-------|--------|-----------|------------------|---------|
| Gemma 3n | … | … | … | pass/fail |
| MedGemma 4B | … | … | … | … |
| Qwen2.5-7B | … | … | … | … |

Plus the recorded decision: chosen model + whether a MedGemma Stage-1 (clinical comprehension) hybrid is needed.
