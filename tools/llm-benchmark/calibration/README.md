# Calibration study — does the judge agree with a human?

The synthetic 240-decision benchmark measures capability against an authored
answer key (see `../error_analysis.md` for how far that key can drift). This
study is the true validation the main README defers to: blind human scores vs
the shipped judge, on fresh material.

## Rules

1. **Role-played transcripts only.** Never real patient audio or notes — this
   directory is in the repo. Record or write 3–5 fresh consultations with a
   colleague; vary quality on purpose (one good, one rushed, one mixed).
2. **Fresh means fresh.** Nothing reused from `criterion_snippets.json`,
   `realistic_cases.json`, or any training set — the point is material neither
   the benchmark nor any fine-tune has seen.
3. **Score blind.** Fill your sheets *before* running (or peeking at) the
   judge. If you saw the judge's output first, the comparison is worthless.

## Workflow

```bash
# 1. add transcripts:  calibration/transcripts/<name>.txt
#    plain text, "Doctor: ..." / "Patient: ..." lines
#    (files starting with "_" are ignored — see _format_example.txt)

python calibration.py sheet     # 2. makes calibration/sheets/<name>.md
#                                 3. YOU fill every "SCORE: ?" (met/partial/missed/na)

python calibration.py judge     # 4. runs the shipped judge (Air + benchmark venv;
#                                    ~2 min per transcript on an Air)

python calibration.py report    # 5. calibration/REPORT.md — agreement + disagreements
```

## Reading the result

- **High binary agreement (roughly ≥ 90%)** → the judge is validated; ship
  as-is. No fine-tune.
- **Systematic disagreement** (same criterion or direction repeatedly) → treat
  the disagreement rows exactly like `../error_analysis.md` treated the
  benchmark misses: decide honestly who is right, you or the judge. If the
  judge is wrong in a pattern → try a prompt fix first, re-run this study;
  fine-tune only if the pattern survives.
- Your blind sheets double as a **held-out human gold set**: if a fine-tune
  ever happens, it must be validated against these (and they must never be
  trained on).
