#!/usr/bin/env python3
"""Print a model's RAW output for a few criteria, so we can see its format and
why the parser might be misreading it.

  python debug_output.py mlx-community/Qwen2.5-7B-Instruct-4bit
"""
import json, sys
from pathlib import Path

from mlx_lm import load, generate

from app_scoring import build_prompt, parse_criterion

HERE = Path(__file__).parent
RUBRIC = HERE.parent.parent / "rubrics" / "outpatient-clinic.json"

model_id = sys.argv[1]
criteria = {c["id"]: c for c in json.loads(RUBRIC.read_text())["criteria"]}
case = json.loads((HERE / "data" / "scoring.json").read_text())[0]

model, tok = load(model_id)

# Show 4 criteria: a couple that should be met, a couple missed.
for cid in ["intro_self", "safety_net", "open_questions", "respond_emotion"]:
    prompt = build_prompt(criteria[cid], case["flat"])
    messages = [{"role": "user", "content": prompt}]
    text = tok.apply_chat_template(messages, add_generation_prompt=True)
    raw = generate(model, tok, prompt=text, max_tokens=180, verbose=False)
    pred, ev = parse_criterion(raw, case["flat"])
    print(f"\n===== {cid}  (truth={case['labels'][cid]}, parsed pred={pred}) =====")
    print("----- RAW MODEL OUTPUT -----")
    print(repr(raw))
    print("----- (end) -----")
