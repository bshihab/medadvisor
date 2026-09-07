"""Score the v4 fine-tuned model on the HUMAN transcripts (h1-h3) — the
missing cell in the ship-config table.

The fine-tune's exclusion was decided on the LLM-authored batch. The human
batch flipped the regime (stock single-pass 85.4 beat the wide verifier's
79.2 there), and the tuned model has never been measured on it. This grades
h1-h3 with base+adapter AND stock (same stack, clean delta), plus the verify
pass for each met verdict of each config, so every scope variant is
computable locally against the consensus gold.

Local entrypoint writes calibration/judge-hT/ (tuned) and judge-hS/ (stock,
in-stack control) with verify verdicts recorded per row (scoping decided at
scoring time locally). Then:
    python ../llm-benchmark/calibration.py report --tag hT   (etc.)

Usage:  modal run modal_tuned_human.py
"""
import json
import sys
from pathlib import Path

import modal

REPO = Path(__file__).resolve().parent.parent.parent
BENCH = REPO / "tools" / "llm-benchmark"
RUBRIC = REPO / "rubrics" / "outpatient-clinic.json"
CAL = BENCH / "calibration" / "transcripts"
R = "/work"
BASE_MODEL = "Qwen/Qwen3.5-4B"
ADAPTER = "/adapters/lr5e-5/step120"
HUMAN = ("h1_stomach", "h2_iron", "h3_ankle")

app = modal.App("medadvisor-tuned-human")

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install("torch>=2.6", "transformers>=4.57", "peft>=0.14", "accelerate",
                 "sentencepiece", "hf_transfer")
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1",
          "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True"})
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
    .add_local_dir(str(CAL), f"{R}/transcripts")
)

hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)
adapters = modal.Volume.from_name("medadvisor-qwen-v4-out")


@app.function(image=image, gpu="A10G", timeout=1800,
              volumes={"/root/.cache/huggingface": hf_cache, "/adapters": adapters})
def run() -> dict:
    import torch
    sys.path.insert(0, R)
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from peft import PeftModel
    from app_scoring import build_prompt, build_verify_prompt, parse_criterion

    criteria = json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]
    cmap = {c["id"]: c for c in criteria}
    tmap = {p.stem: p.read_text().strip()
            for p in Path(f"{R}/transcripts").glob("*.txt") if p.stem in HUMAN}
    assert len(tmap) == 3, sorted(tmap)

    tok = AutoTokenizer.from_pretrained(BASE_MODEL)
    tok.padding_side = "left"
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL, dtype=torch.bfloat16, device_map="cuda")
    model = PeftModel.from_pretrained(model, ADAPTER)
    model.eval()
    model.config.use_cache = True

    def chat(prompt):
        msgs = [{"role": "user", "content": prompt}]
        try:
            return tok.apply_chat_template(msgs, tokenize=False,
                                           add_generation_prompt=True,
                                           enable_thinking=False)
        except TypeError:
            return tok.apply_chat_template(
                [{"role": "user", "content": prompt + "\n/no_think"}],
                tokenize=False, add_generation_prompt=True)

    @torch.no_grad()
    def gen(prompts, max_new, batch=8):
        outs = []
        for i in range(0, len(prompts), batch):
            enc = tok([chat(p) for p in prompts[i:i + batch]],
                      return_tensors="pt", padding=True).to("cuda")
            out = model.generate(**enc, max_new_tokens=max_new, do_sample=False,
                                 pad_token_id=tok.pad_token_id)
            for seq in out:
                outs.append(tok.decode(seq[enc["input_ids"].shape[1]:],
                                       skip_special_tokens=True))
        return outs

    result = {}
    for cfg, use_adapter in (("tuned", True), ("stock", False)):
        ctx = model.enable_adapter_layers if use_adapter else None
        if use_adapter:
            model.enable_adapter_layers()
            rows = grade(tmap, criteria, cmap, gen, parse_criterion,
                         build_prompt, build_verify_prompt)
        else:
            with model.disable_adapter():
                rows = grade(tmap, criteria, cmap, gen, parse_criterion,
                             build_prompt, build_verify_prompt)
        result[cfg] = rows
        print(f"{cfg}: graded+verified {sum(len(v) for v in rows.values())} rows", flush=True)
    return result


def grade(tmap, criteria, cmap, gen, parse_criterion, build_prompt, build_verify_prompt):
    per_tid = {}
    for tid in sorted(tmap):
        raws = gen([build_prompt(c, tmap[tid]) for c in criteria], 180)
        rows = []
        for c, raw in zip(criteria, raws):
            pred, ev = parse_criterion(raw, tmap[tid])
            rows.append({"transcript": tid, "criterion": c["id"], "pred": pred,
                         "evidence": ev, "raw": raw[:400]})
        # verify every met verdict; scoping is applied locally at scoring time
        met = [r for r in rows if r["pred"] == "met"]
        vraws = gen([build_verify_prompt(cmap[r["criterion"]], tmap[tid],
                                         r["evidence"] or "") for r in met], 12)
        for r, v in zip(met, vraws):
            r["verifier"] = v.strip()[:40]
        for r in rows:
            r.setdefault("verifier", "")
        per_tid[tid] = rows
    return per_tid


@app.local_entrypoint()
def main():
    sys.path.insert(0, str(BENCH))
    from app_scoring import verification_rejects

    result = run.remote()
    for cfg, tag in (("tuned", "judge-hT"), ("stock", "judge-hS")):
        outdir = BENCH / "calibration" / tag
        outdir.mkdir(exist_ok=True)
        for tid, rows in result[cfg].items():
            for r in rows:
                # store wide-scope final; narrower scopes recomputed locally
                r["final"] = ("missed" if r["pred"] == "met" and r["verifier"]
                              and verification_rejects(r["verifier"]) else r["pred"])
            (outdir / f"{tid}.json").write_text(json.dumps(
                {"model": f"{BASE_MODEL} (bf16 cloud)",
                 "no_think": True,
                 "adapter": "v4 lr5e-5/step120" if cfg == "tuned" else None,
                 "rows": rows}, indent=2))
        print(f"-> calibration/{tag}/")
    print("\nscore locally against consensus gold (all scopes computable from verifier field)")
