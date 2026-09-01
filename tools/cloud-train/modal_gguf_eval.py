"""Merge the v3 LoRA, quantise to Q4_K_M / Q5_K_M, and measure the SHIPPING file.

The fine-tune measured +9.6 accuracy and -21.4 over-score against stock — but
in bf16 on an NVIDIA GPU. The app ships a GGUF through llama.cpp. Merging and
converting are lossless; QUANTISATION IS NOT, and LoRA moves weights by small
amounts that ~4.5 bits per weight can round away. So the gain has to be
re-measured in the format that actually ships.

Four runs, because "does the tuned model drop at Q4" is unanswerable without
knowing whether STOCK drops at Q4 too. Both models go through an identical
pipeline (same base, same converter, same quantiser, same harness):

    stock  Q4_K_M     tuned  Q4_K_M
    stock  Q5_K_M     tuned  Q5_K_M

Fidelity choices that matter:
- Prompts are built by the app's own app_scoring.build_prompt, and verdicts are
  parsed by the app's own parse_criterion. No reimplementation.
- The ChatML wrapper is byte-for-byte what LLMModel.assistantOpening produces
  in Swift, including the pre-filled empty <think> block that suppresses
  Qwen3.5's reasoning mode. Leaving that out cost us a whole day once: the model
  emitted "Thinking Process:" and labelled 1 of 21 utterances, and I wrote the
  model off as broken when the config was mine.
- /completion with a raw prompt, NOT /chat/completions — the app does its own
  templating, so letting llama-server apply a template would measure a prompt
  the app never sends.

Usage:
  .venv/bin/modal run modal_gguf_eval.py
"""
import json
from pathlib import Path

import modal

BENCH = Path.home() / "bilal-dev/medadvisor-ane/tools/llm-benchmark"
RUBRIC = Path.home() / "bilal-dev/medadvisor-ane/rubrics/outpatient-clinic.json"
R = "/work"
BASE_MODEL = "Qwen/Qwen3.5-4B"

# The v3 winner: lr5e-5, step 180. Chosen on the hand-written cases, then
# confirmed on the 240 set it had never been selected against.
ADAPTER = "/out/lr5e-5/step180"

app = modal.App("medadvisor-gguf-eval")

image = (
    # A CUDA *devel* base, not debian_slim: compiling ggml-cuda needs nvcc, and
    # pip's torch ships only the CUDA runtime. Without this, cmake configures
    # with -DGGML_CUDA=ON and then fails to find a CUDA compiler.
    modal.Image.from_registry("nvidia/cuda:12.8.1-devel-ubuntu24.04",
                              add_python="3.11")
    .apt_install("git", "build-essential", "cmake", "curl", "libcurl4-openssl-dev")
    .pip_install("torch>=2.6", "transformers>=4.57", "peft>=0.14", "accelerate",
                 "sentencepiece", "hf_transfer", "requests", "numpy")
    .run_commands(
        "git clone --depth 1 https://github.com/ggml-org/llama.cpp /llama.cpp",
        # CMAKE_CUDA_ARCHITECTURES=86 is the difference between a ~12 minute
        # build and a ~90 minute one. By default ggml compiles its flash-attention
        # and mmq template instances for every supported architecture; we run on
        # exactly one GPU (A10G = compute capability 8.6), so the rest is pure
        # waste. Measured before pinning it: 0.8% progress per minute.
        "cmake -S /llama.cpp -B /llama.cpp/build -DGGML_CUDA=ON -DLLAMA_CURL=OFF "
        "-DCMAKE_CUDA_ARCHITECTURES=86 -DCMAKE_BUILD_TYPE=Release",
        "cmake --build /llama.cpp/build --config Release -j 8 "
        "--target llama-quantize llama-server",
        "pip install -r /llama.cpp/requirements/requirements-convert_hf_to_gguf.txt",
        # MUST come after llama.cpp's requirements file, which pins an older
        # transformers and silently downgrades the one installed above. That
        # older version does not know the `qwen3_5` architecture, so both the
        # merge and the GGUF conversion die with KeyError: 'qwen3_5'.
        "pip install --upgrade 'transformers>=4.57' 'tokenizers>=0.21'",
        gpu="A10G",          # CUDA toolkit must see a device to build ggml-cuda
    )
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(BENCH / "realistic_cases.json"), f"{R}/realistic_cases.json")
    .add_local_file(str(BENCH / "data/scoring.json"), f"{R}/scoring.json")
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
)

hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)
out_vol = modal.Volume.from_name("medadvisor-qwen-v3-out", create_if_missing=True)
gguf_vol = modal.Volume.from_name("medadvisor-gguf", create_if_missing=True)

QUANTS = ["Q4_K_M", "Q5_K_M"]

BUDGET_USD = 8.00
GPU = "A10G"
GPU_HOURLY_USD = 1.10
PREP_TIMEOUT_S = int(2.5 / GPU_HOURLY_USD * 3600)
BENCH_TIMEOUT_S = int(1.5 / GPU_HOURLY_USD * 3600)

# Exactly what Sources/LLMModel.swift emits for .qwen35_4B. The empty <think>
# block is the reasoning-mode suppression; it is not decorative.
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
    """Merge the adapter, convert both models to F16 GGUF, quantise each.

    Merging and F16 conversion are lossless; every quantised file below comes
    from the same converter and quantiser, so a stock-vs-tuned difference cannot
    be an artefact of the pipeline.
    """
    import shutil, torch
    from huggingface_hub import snapshot_download
    from safetensors.torch import load_file, save_file

    # NEVER round-trip through AutoModelForCausalLM. Qwen3.5 carries an MTP
    # (multi-token prediction) layer as block 32 — tensors named nextn.eh_proj,
    # nextn.enorm, nextn.hnorm, nextn.shared_head_norm. That layer is not part of
    # the causal-LM graph, so from_pretrained never loads it and save_pretrained
    # silently drops it: our first GGUF had 426 tensors where the reference has
    # 441, and llama.cpp refused it with "missing tensor blk.32.attn_norm.weight".
    #
    # Instead: copy the original snapshot verbatim and apply the LoRA deltas to
    # the weight shards in place. Everything the adapter does not touch — the MTP
    # layer included — passes through byte-identical.
    snap = snapshot_download(BASE_MODEL)

    built = []
    for name, use_adapter in (("stock", False), ("tuned", True)):
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
                # peft: base_model.model.<base key minus '.weight'>.lora_A.weight
                # peft records the module path as transformers EXPOSES it
                # (model.layers.N...), but this checkpoint STORES weights as
                # model.language_model.layers.N... — the same reason the MTP
                # block lives under a separate top-level `mtp.` prefix. Matching
                # naively applied 0 of 128 deltas, which the guard below caught.
                deltas = {}
                for k, v in lora.items():
                    if ".lora_A" not in k:
                        continue
                    base = (k.replace("base_model.model.", "")
                             .replace(".lora_A.weight", ".weight"))
                    B = lora[k.replace(".lora_A.", ".lora_B.")]
                    d = (B.float() @ v.float()) * scaling
                    deltas[base] = d
                    # accept either layout; whichever key the shard actually has wins
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
                # deltas holds two candidate key spellings per module, so the
                # expected count is the module count, not len(deltas).
                if applied != n_modules:
                    raise RuntimeError(
                        f"applied {applied} of {n_modules} LoRA deltas — key mismatch")
                print(f"[{name}] merged {applied} tensors in place", flush=True)

            _sh(["python", "/llama.cpp/convert_hf_to_gguf.py", merged,
                 "--outfile", f16, "--outtype", "f16"], f"[{name}] convert f16")
            # The reference conversion has 441 tensors. Fewer means something was
            # dropped again, and it is far cheaper to fail here than after
            # quantising and launching four benchmark containers.
            from gguf import GGUFReader
            ntensors = len(GGUFReader(f16).tensors)
            print(f"[{name}] GGUF has {ntensors} tensors (reference: 441)", flush=True)
            if ntensors < 441:
                raise RuntimeError(f"[{name}] GGUF incomplete: {ntensors} < 441 tensors")
        for q in QUANTS:
            out = f"/gguf/{name}-{q}.gguf"
            if not Path(out).exists():
                _sh(["/llama.cpp/build/bin/llama-quantize", f16, out, q],
                    f"[{name}] quantise {q}")
            built.append(out)
            print(f"[{name}] {q}: {Path(out).stat().st_size/2**30:.2f} GB", flush=True)
        gguf_vol.commit()
    return built


@app.function(image=image, gpu=GPU, timeout=BENCH_TIMEOUT_S,
              volumes={"/gguf": gguf_vol})
def bench(name: str, quant: str) -> dict:
    """Score one GGUF with llama.cpp — the same engine the app ships."""
    import subprocess, sys, time, requests
    sys.path.insert(0, R)
    from app_scoring import build_prompt, parse_criterion

    gguf = f"/gguf/{name}-{quant}.gguf"
    criteria = {c["id"]: c for c in json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]}

    # Keep the server's own output: discarding it last time meant a startup
    # failure reported nothing but "never came up".
    log = open(f"/tmp/{name}-{quant}-server.log", "w+")
    srv = subprocess.Popen(
        ["/llama.cpp/build/bin/llama-server", "-m", gguf, "-c", "4096",
         "-ngl", "99", "--port", "8080", "--host", "127.0.0.1", "-t", "8"],
        stdout=log, stderr=subprocess.STDOUT)
    ready = False
    for _ in range(240):
        if srv.poll() is not None:            # died outright — no point waiting
            break
        try:
            # llama-server answers 503 WHILE LOADING. That is a successful HTTP
            # response, not an exception, so sleeping only inside `except` spun
            # through every retry in milliseconds and gave up before the model
            # had loaded. The sleep belongs on every iteration.
            if requests.get("http://127.0.0.1:8080/health", timeout=2).status_code == 200:
                ready = True
                break
        except Exception:
            pass
        time.sleep(1)
    if not ready:
        srv.kill()
        log.seek(0)
        raise RuntimeError(f"llama-server never came up for {gguf}\n"
                           f"--- server log ---\n{log.read()[-2000:]}")

    def run(prompt: str) -> str:
        full = f"<|im_start|>user\n{prompt}<|im_end|>\n{ASSISTANT_OPENING}"
        r = requests.post("http://127.0.0.1:8080/completion", timeout=180, json={
            "prompt": full, "n_predict": 180, "temperature": 0,
            "cache_prompt": True,          # the app's KV prefix cache
            "stop": ["<|im_end|>"]})
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
        print(f"[{name} {quant}] {label:<8} acc {results[label]['acc']:5.1f}%  "
              f"over {results[label]['over']:5.1f}%  recall {results[label]['recall']:5.1f}%",
              flush=True)

    srv.kill()
    return {"name": name, "quant": quant,
            "size_gb": Path(gguf).stat().st_size / 2**30, **results}


@app.local_entrypoint()
def main():
    print(f"preparing GGUFs (merge + convert + quantise {', '.join(QUANTS)})…")
    prepare.remote()

    combos = [(n, q) for q in QUANTS for n in ("stock", "tuned")]
    print(f"benchmarking {len(combos)} files in parallel…")
    out = {}
    for combo, r in zip(combos, bench.starmap(combos, return_exceptions=True)):
        if isinstance(r, Exception):
            print(f"!! {combo} FAILED: {type(r).__name__}: {r}")
        else:
            out[(r["name"], r["quant"])] = r

    lines = ["=" * 74,
             "Qwen3.5-4B v3 fine-tune — measured as the SHIPPING GGUF (llama.cpp)",
             "=" * 74,
             "Merge and F16 conversion are lossless. Quantisation is not, so stock",
             "is quantised through the identical pipeline and measured alongside.",
             ""]
    for q in QUANTS:
        s, t = out.get(("stock", q)), out.get(("tuned", q))
        if not (s and t):
            lines.append(f"--- {q}: incomplete ---")
            continue
        lines.append(f"--- {q}  ({t['size_gb']:.2f} GB) ---")
        for label in ("240", "48-case"):
            lines += [f"  {label} set:",
                      f"    stock   acc {s[label]['acc']:5.1f}%  over {s[label]['over']:5.1f}%  recall {s[label]['recall']:5.1f}%",
                      f"    tuned   acc {t[label]['acc']:5.1f}%  over {t[label]['over']:5.1f}%  recall {t[label]['recall']:5.1f}%",
                      f"    DELTA   acc {t[label]['acc']-s[label]['acc']:+5.1f}   "
                      f"over {t[label]['over']-s[label]['over']:+5.1f}   "
                      f"recall {t[label]['recall']-s[label]['recall']:+5.1f}"]
        lines.append("")
    lines += ["bf16 on GPU measured: acc +9.6, over -21.4, recall -0.8 (240 set).",
              "How much of that survives above is the whole question.", ""]
    text = "\n".join(lines)
    (BENCH / "results" / "V3-GGUF-REPORT.txt").write_text(text)
    print("\n" + text)
