"""Measure the untested combination: v4 adapter + second-pass verifier.

The v4 adapter alone scored 74.6% on calibration gold; stock + scoped
verifier scores 84.1%. This job answers whether they STACK: it runs the
12-token CONFIRM/REJECT verify call for every 'met' verdict already recorded
in calibration/judge-v4cloud/ (tuned) and judge-v4cloud-stock/ (stock, same
stack, for a clean comparison), using the same model configuration that
produced the verdict — the adapter's verify behaviour is itself untested.

Nothing is retrained. The adapter is loaded from the v4 run's Modal volume
(medadvisor-qwen-v4-out, lr5e-5/step120). Cost: a few GPU-minutes.

The local entrypoint composes judge dirs with 'final' fields so the audited
local calibration.py computes the numbers against Bilal's gold:
  scoped  = rejections applied except aggregate criteria (explore_complaint,
            plain_language — the verifier's known damage zone)
  full    = all rejections applied (for science)

  python ../llm-benchmark/calibration.py report --tag v4cloud-vscoped
  python ../llm-benchmark/calibration.py report --tag v4stock-vscoped

Usage:  modal run modal_verify_stack.py
"""
import json
import sys
from pathlib import Path

import modal

REPO = Path(__file__).resolve().parent.parent.parent
BENCH = REPO / "tools" / "llm-benchmark"
RUBRIC = REPO / "rubrics" / "outpatient-clinic.json"
CAL = BENCH / "calibration"
R = "/work"

BASE_MODEL = "Qwen/Qwen3.5-4B"
ADAPTER = "/adapters/lr5e-5/step120"
AGGREGATE = {"explore_complaint", "plain_language"}

app = modal.App("medadvisor-verify-stack")

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install("torch>=2.6", "transformers>=4.57", "peft>=0.14", "accelerate",
                 "sentencepiece", "hf_transfer")
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1",
          "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True"})
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
    .add_local_dir(str(CAL / "transcripts"), f"{R}/transcripts")
    .add_local_dir(str(CAL / "judge-v4cloud"), f"{R}/judge-tuned")
    .add_local_dir(str(CAL / "judge-v4cloud-stock"), f"{R}/judge-stock")
)

hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)
adapters = modal.Volume.from_name("medadvisor-qwen-v4-out")


@app.function(image=image, gpu="A10G", timeout=900,
              volumes={"/root/.cache/huggingface": hf_cache, "/adapters": adapters})
def run_verify() -> dict:
    import torch
    sys.path.insert(0, R)
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from peft import PeftModel
    from app_scoring import build_verify_prompt

    criteria = {c["id"]: c for c in json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]}
    tmap = {p.stem: p.read_text().strip()
            for p in Path(f"{R}/transcripts").glob("*.txt") if not p.stem.startswith("_")}

    tok = AutoTokenizer.from_pretrained(BASE_MODEL)
    tok.padding_side = "left"
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL, dtype=torch.bfloat16, device_map="cuda")
    model = PeftModel.from_pretrained(model, ADAPTER)
    model.eval()
    model.config.use_cache = True

    def chat(prompt: str) -> str:
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
    def verify_batch(jobs, batch=16):
        replies = []
        for i in range(0, len(jobs), batch):
            chunk = jobs[i:i + batch]
            enc = tok([chat(build_verify_prompt(criteria[cid], tmap[tid], ev or ""))
                       for tid, cid, ev in chunk],
                      return_tensors="pt", padding=True).to("cuda")
            out = model.generate(**enc, max_new_tokens=12, do_sample=False,
                                 pad_token_id=tok.pad_token_id)
            for seq in out:
                replies.append(tok.decode(seq[enc["input_ids"].shape[1]:],
                                          skip_special_tokens=True).strip())
        return replies

    result = {}
    for cfg, use_adapter in (("tuned", True), ("stock", False)):
        jobs = [(r["transcript"], r["criterion"], r.get("evidence"))
                for f in sorted(Path(f"{R}/judge-{cfg}").glob("*.json"))
                for r in json.loads(f.read_text())["rows"] if r["pred"] == "met"]
        if use_adapter:
            model.enable_adapter_layers()
            replies = verify_batch(jobs)
        else:
            with model.disable_adapter():
                replies = verify_batch(jobs)
        result[cfg] = {f"{tid}|{cid}": rep for (tid, cid, _), rep in zip(jobs, replies)}
        print(f"{cfg}: verified {len(jobs)} 'met' verdicts", flush=True)
    return result


def compose(src_dir: str, out_tag: str, verdicts: dict, scoped: bool):
    from app_scoring import verification_rejects  # local import, same file the job used
    src = CAL / src_dir
    out = CAL / f"judge-{out_tag}"
    out.mkdir(exist_ok=True)
    for f in sorted(src.glob("*.json")):
        d = json.loads(f.read_text())
        for r in d["rows"]:
            key = f"{r['transcript']}|{r['criterion']}"
            if r["pred"] == "met" and key in verdicts:
                rep = verdicts[key]
                reject = verification_rejects(rep)
                if scoped and r["criterion"] in AGGREGATE:
                    reject = False
                r["final"] = "missed" if reject else "met"
                r["verifier"] = rep[:40]
            else:
                r["final"] = r["pred"]
                r["verifier"] = ""
        (out / f.name).write_text(json.dumps(d, indent=2))
    print(f"-> judge-{out_tag}/")


@app.local_entrypoint()
def main():
    sys.path.insert(0, str(BENCH))
    result = run_verify.remote()
    compose("judge-v4cloud", "v4cloud-vscoped", result["tuned"], scoped=True)
    compose("judge-v4cloud", "v4cloud-vfull", result["tuned"], scoped=False)
    compose("judge-v4cloud-stock", "v4stock-vscoped", result["stock"], scoped=True)
    compose("judge-v4cloud-stock", "v4stock-vfull", result["stock"], scoped=False)
    print("\nDECIDE locally:")
    for tag in ("v4cloud-vscoped", "v4cloud-vfull", "v4stock-vscoped", "v4stock-vfull"):
        print(f"  python ../llm-benchmark/calibration.py report --tag {tag}")
