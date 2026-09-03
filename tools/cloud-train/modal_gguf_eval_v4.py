"""Merge the v4 LoRA, quantise to Q4_K_M, and measure the would-ship file.

Ramp 1 of the fine-tune's exit ramps: if the verifier's second call proves too
costly on real hardware, single-call mode ships the tuned model instead — but
only if the gain survives quantisation. This produces the artifact
(v4tuned-Q4_K_M.gguf on the medadvisor-gguf volume, ready for R2) and its
numbers in the exact shipping stack (llama.cpp, ChatML + empty <think> block,
raw /completion), including the decision metric: single-pass calibration rows
for the local audited scorer.

Pipeline identical to modal_gguf_eval.py (v3), which survived three traps its
comments document. Deltas: v4 adapter (lr5e-5/step120 on medadvisor-qwen-v4-out),
Q4_K_M only (the shipping quant; v3 already characterised Q5), v4- file prefix
so v3's GGUFs are untouched, and the calibration transcripts measured alongside
the 48/240 sets. After the run:

    python ../llm-benchmark/calibration.py report --tag v4gguf         # tuned
    python ../llm-benchmark/calibration.py report --tag v4gguf-stock   # stock

Bars for single-call mode: tuned bf16 single-pass measured 74.6% vs gold
(stock 65.1%). If Q4_K_M holds ~that, the artifact is ship-ready for the
niche; the DEFAULT config remains stock + scoped verifier (81-84%).

Usage:  modal run modal_gguf_eval_v4.py
"""
import json
from pathlib import Path

import modal

REPO = Path(__file__).resolve().parent.parent.parent
BENCH = REPO / "tools" / "llm-benchmark"
RUBRIC = REPO / "rubrics" / "outpatient-clinic.json"
CAL = BENCH / "calibration" / "transcripts"
R = "/work"
BASE_MODEL = "Qwen/Qwen3.5-4B"

# The v4 winner: lr5e-5, step 120 (selected on the 48-case screen, recall floor).
ADAPTER = "/out/lr5e-5/step120"

app = modal.App("medadvisor-gguf-eval-v4")

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
        # Must come after llama.cpp's requirements (which pin an older
        # transformers that does not know the qwen3_5 architecture).
        "pip install --upgrade 'transformers>=4.57' 'tokenizers>=0.21'",
        gpu="A10G",
    )
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(BENCH / "realistic_cases.json"), f"{R}/realistic_cases.json")
    .add_local_file(str(BENCH / "data/scoring.json"), f"{R}/scoring.json")
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
    .add_local_dir(str(CAL), f"{R}/calibration")
)

hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)
out_vol = modal.Volume.from_name("medadvisor-qwen-v4-out")
gguf_vol = modal.Volume.from_name("medadvisor-gguf", create_if_missing=True)

QUANT = "Q4_K_M"
GPU = "A10G"
PREP_TIMEOUT_S = 5400
BENCH_TIMEOUT_S = 5400

# Exactly what Sources/LLMModel.swift emits for .qwen35_4B.
ASSISTANT_OPENING = "<|im_start|>assistant\n<think>\n\n</think>\n\n"


def _sh(cmd: list[str], label: str):
    import subprocess
    print(f"\n=== {label} ===\n$ {' '.join(cmd)}", flush=True)
    p = subprocess.run(cmd, capture_output=True, text=True)
    print((p.stdout or "")[-2500:], (p.stderr or "")[-2500:], flush=True)
    if p.returncode != 0:
        raise RuntimeError(f"{label} failed (exit {p.returncode})")


@app.function(image=image, gpu=GPU, timeout=PREP_TIMEOUT_S,
              volumes={"/root/.cache/huggingface": hf_cache, "/out": out_vol,
                       "/gguf": gguf_vol})
def prepare() -> list[str]:
    """Merge the adapter into a verbatim snapshot copy (NEVER via
    AutoModelForCausalLM — Qwen3.5's MTP block would be silently dropped),
    convert to F16 GGUF, quantise. Stock goes through the identical pipeline."""
    import shutil
    from huggingface_hub import snapshot_download
    from safetensors.torch import load_file, save_file

    snap = snapshot_download(BASE_MODEL)
    built = []
    for name, use_adapter in (("v4stock", False), ("v4tuned", True)):
        merged = f"/gguf/{name}-bf16"
        f16 = f"/gguf/{name}-f16.gguf"
        if not Path(f16).exists():
            print(f"[{name}] copying snapshot…", flush=True)
            shutil.copytree(snap, merged, dirs_exist_ok=True, symlinks=False)
            if use_adapter:
                if not Path(ADAPTER).exists():
                    raise RuntimeError(f"adapter missing at {ADAPTER}")
                lora = load_file(f"{ADAPTER}/adapter_model.safetensors")
                cfg = json.loads(Path(f"{ADAPTER}/adapter_config.json").read_text())
                scaling = cfg["lora_alpha"] / cfg["r"]
                deltas = {}
                for k, v in lora.items():
                    if ".lora_A" not in k:
                        continue
                    base = (k.replace("base_model.model.", "")
                             .replace(".lora_A.weight", ".weight"))
                    B = lora[k.replace(".lora_A.", ".lora_B.")]
                    d = (B.float() @ v.float()) * scaling
                    deltas[base] = d
                    deltas[base.replace("model.layers.",
                                        "model.language_model.layers.")] = d
                n_modules = sum(1 for k in lora if ".lora_A" in k)
                print(f"[{name}] {n_modules} LoRA modules, scaling={scaling}", flush=True)
                applied = 0
                for shard in sorted(Path(merged).glob("*.safetensors")):
                    t = load_file(str(shard))
                    hit = False
                    for key in list(t.keys()):
                        if key in deltas:
                            t[key] = (t[key].float() + deltas[key]).to(t[key].dtype)
                            applied += 1
                            hit = True
                    if hit:
                        save_file(t, str(shard), metadata={"format": "pt"})
                    del t
                if applied != n_modules:
                    raise RuntimeError(
                        f"applied {applied} of {n_modules} LoRA deltas — key mismatch")
                print(f"[{name}] merged {applied} tensors in place", flush=True)

            _sh(["python", "/llama.cpp/convert_hf_to_gguf.py", merged,
                 "--outfile", f16, "--outtype", "f16"], f"[{name}] convert f16")
            from gguf import GGUFReader
            ntensors = len(GGUFReader(f16).tensors)
            print(f"[{name}] GGUF has {ntensors} tensors (reference: 441)", flush=True)
            if ntensors < 441:
                raise RuntimeError(f"[{name}] GGUF incomplete: {ntensors} < 441 tensors")
        out = f"/gguf/{name}-{QUANT}.gguf"
        if not Path(out).exists():
            _sh(["/llama.cpp/build/bin/llama-quantize", f16, out, QUANT],
                f"[{name}] quantise {QUANT}")
        built.append(out)
        print(f"[{name}] {QUANT}: {Path(out).stat().st_size/2**30:.2f} GB", flush=True)
        gguf_vol.commit()
    return built


@app.function(image=image, gpu=GPU, timeout=BENCH_TIMEOUT_S,
              volumes={"/gguf": gguf_vol})
def bench(name: str) -> dict:
    """Score one GGUF with llama.cpp — the engine the app ships. Returns the
    48/240 metrics plus per-decision calibration rows for local scoring."""
    import subprocess, sys, time, requests
    sys.path.insert(0, R)
    from app_scoring import build_prompt, parse_criterion

    gguf = f"/gguf/{name}-{QUANT}.gguf"
    criteria = {c["id"]: c for c in json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]}
    crit_order = list(criteria)

    log = open(f"/tmp/{name}-server.log", "w+")
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
        time.sleep(1)   # llama-server answers 503 while loading — sleep every loop
    if not ready:
        srv.kill()
        log.seek(0)
        raise RuntimeError(f"llama-server never came up for {gguf}\n"
                           f"--- server log ---\n{log.read()[-2000:]}")

    def run(prompt: str) -> str:
        full = f"<|im_start|>user\n{prompt}<|im_end|>\n{ASSISTANT_OPENING}"
        r = requests.post("http://127.0.0.1:8080/completion", timeout=180, json={
            "prompt": full, "n_predict": 180, "temperature": 0,
            "cache_prompt": True, "stop": ["<|im_end|>"]})
        return r.json().get("content", "")

    results = {}
    for label, path in (("48-case", f"{R}/realistic_cases.json"),
                        ("240", f"{R}/scoring.json")):
        cases = json.loads(Path(path).read_text())
        rows = []
        for c in cases:
            for cid, truth in c["labels"].items():
                pred, _ = parse_criterion(run(build_prompt(criteria[cid], c["flat"])), c["flat"])
                rows.append({"truth": truth, "pred": pred,
                             "correct": (pred == "met") == (truth == "met")})
        n = len(rows)
        missed = [r for r in rows if r["truth"] == "missed"]
        met = [r for r in rows if r["truth"] == "met"]
        results[label] = dict(
            n=n, acc=sum(r["correct"] for r in rows) / n * 100,
            over=sum(r["pred"] == "met" for r in missed) / len(missed) * 100 if missed else 0.0,
            recall=sum(r["pred"] == "met" for r in met) / len(met) * 100 if met else 0.0)
        print(f"[{name}] {label:<8} acc {results[label]['acc']:5.1f}%  "
              f"over {results[label]['over']:5.1f}%  recall {results[label]['recall']:5.1f}%",
              flush=True)

    # The decision metric: single-pass calibration rows, scored locally.
    tmap = {p.stem: p.read_text().strip()
            for p in Path(f"{R}/calibration").glob("*.txt") if not p.stem.startswith("_")}
    cal = {}
    for tid in sorted(tmap):
        rows = []
        for cid in crit_order:
            raw = run(build_prompt(criteria[cid], tmap[tid]))
            pred, ev = parse_criterion(raw, tmap[tid])
            rows.append({"transcript": tid, "criterion": cid, "pred": pred,
                         "evidence": ev, "raw": raw[:400]})
        cal[tid] = rows
    print(f"[{name}] calibration rows generated ({sum(len(v) for v in cal.values())})",
          flush=True)

    srv.kill()
    return {"name": name, "size_gb": Path(gguf).stat().st_size / 2**30,
            "cal": cal, **results}


@app.local_entrypoint()
def main():
    print(f"preparing v4 GGUFs (merge + convert + quantise {QUANT})…")
    prepare.remote()

    print("benchmarking stock and tuned in parallel…")
    out = {}
    for name, r in zip(("v4stock", "v4tuned"),
                       bench.map(("v4stock", "v4tuned"), return_exceptions=True)):
        if isinstance(r, Exception):
            print(f"!! {name} FAILED: {type(r).__name__}: {r}")
        else:
            out[name] = r

    lines = ["=" * 74,
             "Qwen3.5-4B v4 fine-tune — measured as a would-ship GGUF (llama.cpp)",
             "=" * 74,
             "Ramp 1 artifact: single-call mode candidate. Default ship config",
             "remains stock + scoped verifier; this file matters only if the",
             "verifier's on-device cost proves too high (see [Verify] TOTAL in",
             "the app console).", ""]
    s, t = out.get("v4stock"), out.get("v4tuned")
    if s and t:
        lines.append(f"--- {QUANT}  ({t['size_gb']:.2f} GB) ---")
        for label in ("240", "48-case"):
            lines += [f"  {label} set:",
                      f"    stock   acc {s[label]['acc']:5.1f}%  over {s[label]['over']:5.1f}%  recall {s[label]['recall']:5.1f}%",
                      f"    tuned   acc {t[label]['acc']:5.1f}%  over {t[label]['over']:5.1f}%  recall {t[label]['recall']:5.1f}%",
                      f"    DELTA   acc {t[label]['acc']-s[label]['acc']:+5.1f}   "
                      f"over {t[label]['over']-s[label]['over']:+5.1f}   "
                      f"recall {t[label]['recall']-s[label]['recall']:+5.1f}"]
        for name, tag in (("v4stock", "judge-v4gguf-stock"), ("v4tuned", "judge-v4gguf")):
            d = BENCH / "calibration" / tag
            d.mkdir(parents=True, exist_ok=True)
            for tid, rows in out[name]["cal"].items():
                (d / f"{tid}.json").write_text(json.dumps(
                    {"model": f"Qwen3.5-4B {QUANT} GGUF/llama.cpp",
                     "no_think": True,
                     "adapter": "v4 lr5e-5/step120 (merged)" if name == "v4tuned" else None,
                     "rows": rows}, indent=2))
            print(f"calibration rows -> {d}/")
        lines += ["", "DECIDE locally (bf16 bars: tuned 74.6%, stock 65.1%):",
                  "  python ../llm-benchmark/calibration.py report --tag v4gguf",
                  "  python ../llm-benchmark/calibration.py report --tag v4gguf-stock",
                  "", "Artifact: v4tuned-Q4_K_M.gguf on the medadvisor-gguf volume —",
                  "download with `modal volume get medadvisor-gguf v4tuned-Q4_K_M.gguf`",
                  "and host on R2 if single-call mode is ever adopted."]
    text = "\n".join(lines)
    (BENCH / "results" / "V4-GGUF-REPORT.txt").write_text(text)
    print("\n" + text)
