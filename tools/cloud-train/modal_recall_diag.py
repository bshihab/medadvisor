"""Which behaviours does the fine-tune now WRONGLY call missed?

The v3 tuned model is better on every aggregate measure — accuracy 84.2 -> 95.8,
over-scoring 33.9 -> 8.9 on the 240 set. But on the hand-written 48-case set its
recall fell 100% -> 83.3%, identically at Q4_K_M and Q5_K_M, so it is a property
of the fine-tune rather than quantisation noise. Three genuinely-demonstrated
behaviours are being marked missed.

That matters more than the aggregate suggests. Over-crediting flatters a doctor;
under-crediting tells them they failed to do something they actually did, in an
app whose whole claim is that a medical educator's rubric was applied faithfully.
One wrong "you never introduced yourself" costs more trust than several generous
verdicts.

This prints, for every criterion the tuned model calls missed but truth says met:
the criterion, the transcript line that demonstrates it, and the model's RAW
output — so the failure can be read rather than inferred. Stock's verdict on the
same criterion is printed alongside, which separates "the fine-tune broke this"
from "neither model ever got it".

Cheap: one GPU container, 48 decisions x 2 models, ~4 minutes.
"""
import json
from pathlib import Path

import modal

BENCH = Path.home() / "bilal-dev/medadvisor-ane/tools/llm-benchmark"
RUBRIC = Path.home() / "bilal-dev/medadvisor-ane/rubrics/outpatient-clinic.json"
R = "/work"

app = modal.App("medadvisor-recall-diag")

image = (
    modal.Image.from_registry("nvidia/cuda:12.8.1-devel-ubuntu24.04",
                              add_python="3.11")
    .apt_install("git", "build-essential", "cmake", "curl", "libcurl4-openssl-dev")
    .pip_install("torch>=2.6", "transformers>=4.57", "peft>=0.14", "accelerate",
                 "sentencepiece", "hf_transfer", "requests", "numpy")
    .run_commands(
        "git clone --depth 1 https://github.com/ggml-org/llama.cpp /llama.cpp",
        "cmake -S /llama.cpp -B /llama.cpp/build -DGGML_CUDA=ON -DLLAMA_CURL=OFF "
        "-DCMAKE_CUDA_ARCHITECTURES=86 -DCMAKE_BUILD_TYPE=Release",
        "cmake --build /llama.cpp/build --config Release -j 8 "
        "--target llama-quantize llama-server",
        "pip install -r /llama.cpp/requirements/requirements-convert_hf_to_gguf.txt",
        "pip install --upgrade 'transformers>=4.57' 'tokenizers>=0.21'",
        gpu="A10G",
    )
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(BENCH / "realistic_cases.json"), f"{R}/realistic_cases.json")
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
)

gguf_vol = modal.Volume.from_name("medadvisor-gguf", create_if_missing=True)
ASSISTANT_OPENING = "<|im_start|>assistant\n<think>\n\n</think>\n\n"


@app.function(image=image, gpu="A10G", timeout=3000, volumes={"/gguf": gguf_vol})
def diag() -> dict:
    import subprocess, sys, time, requests
    sys.path.insert(0, R)
    from app_scoring import build_prompt, parse_criterion

    criteria = {c["id"]: c for c in json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]}
    cases = json.loads(Path(f"{R}/realistic_cases.json").read_text())

    def score_all(gguf):
        log = open("/tmp/srv.log", "w+")
        srv = subprocess.Popen(
            ["/llama.cpp/build/bin/llama-server", "-m", gguf, "-c", "4096",
             "-ngl", "99", "--port", "8080", "--host", "127.0.0.1", "-t", "8"],
            stdout=log, stderr=subprocess.STDOUT)
        ready = False
        for _ in range(240):
            if srv.poll() is not None:
                break
            try:
                if requests.get("http://127.0.0.1:8080/health", timeout=2).status_code == 200:
                    ready = True
                    break
            except Exception:
                pass
            time.sleep(1)
        if not ready:
            srv.kill(); log.seek(0)
            raise RuntimeError(f"server failed for {gguf}\n{log.read()[-1500:]}")

        out = {}
        for c in cases:
            for cid, truth in c["labels"].items():
                full = (f"<|im_start|>user\n{build_prompt(criteria[cid], c['flat'])}"
                        f"<|im_end|>\n{ASSISTANT_OPENING}")
                raw = requests.post("http://127.0.0.1:8080/completion", timeout=180, json={
                    "prompt": full, "n_predict": 180, "temperature": 0,
                    "cache_prompt": True, "stop": ["<|im_end|>"]}).json().get("content", "")
                pred, ev = parse_criterion(raw, c["flat"])
                out[(c["id"], cid)] = {"truth": truth, "pred": pred,
                                       "evidence": ev, "raw": raw.strip()[:600]}
        srv.kill()
        return out

    tuned = score_all("/gguf/tuned-Q4_K_M.gguf")
    stock = score_all("/gguf/stock-Q4_K_M.gguf")

    lost = []
    for k, t in tuned.items():
        if t["truth"] == "met" and t["pred"] != "met":
            case_id, cid = k
            lost.append({
                "case": case_id, "criterion": cid,
                "prompt_text": criteria[cid]["prompt"],
                "good": criteria[cid].get("whatGoodLooksLike", ""),
                "tuned_raw": t["raw"],
                "stock_pred": stock[k]["pred"],
                "stock_evidence": (stock[k]["evidence"] or "")[:200],
                "transcript": next(c["flat"] for c in cases if c["id"] == case_id)[:1200],
            })
    return {"lost": lost,
            "tuned_recall_denom": sum(1 for v in tuned.values() if v["truth"] == "met"),
            "stock_lost": sum(1 for v in stock.values()
                              if v["truth"] == "met" and v["pred"] != "met")}


@app.local_entrypoint()
def main():
    r = diag.remote()
    lines = ["=" * 74,
             "RECALL REGRESSION — behaviours the tuned model wrongly calls missed",
             "=" * 74,
             f"tuned lost {len(r['lost'])} of {r['tuned_recall_denom']} met criteria "
             f"(stock lost {r['stock_lost']})", ""]
    for i, x in enumerate(r["lost"], 1):
        lines += [f"--- {i}. {x['case']} / {x['criterion']} ---",
                  f"  criterion : {x['prompt_text']}",
                  f"  good looks like: {x['good']}",
                  f"  STOCK said: {x['stock_pred']}"
                  + (f"  evidence: \"{x['stock_evidence']}\"" if x["stock_evidence"] else ""),
                  "  TUNED said:",
                  *[f"      {l}" for l in x["tuned_raw"].splitlines()[:8]],
                  ""]
    if r["lost"]:
        lines += ["TRANSCRIPT of the first failing case (for reading the verdicts):",
                  *[f"  {l}" for l in r["lost"][0]["transcript"].splitlines()[:30]], ""]
    text = "\n".join(lines)
    (BENCH / "results" / "V3-RECALL-DIAG.txt").write_text(text)
    print(text)
