"""Run ONE transcript through BOTH shipping models and print them side by side.

Why this instead of recording twice: re-reading the script introduces a second
variable. Speech-to-text will not produce identical text twice -- different
disfluencies, different punctuation, occasionally a different speaker label -- so
a difference in the verdicts could be the transcript rather than the model. One
transcript, two models, everything else held constant.

Fidelity, so this is comparable to what the phone does:
  - prompts from the app's own app_scoring.build_prompt
  - verdicts parsed by the app's own parse_criterion
  - llama.cpp b10243 -- the build the app now ships after the b7484 bump
  - per-model ChatML wrapper copied from LLMModel.assistantOpening, including the
    empty <think> block for Qwen3.5 (leave it out and the model burns its budget
    on "Thinking Process:" and never reaches a verdict)

What it prints, per criterion: each model's verdict, the evidence it quoted, and
the tip it wrote. The verdicts answer "which model grades better". The TIPS
answer the question no metric covers -- whether the feedback is worth reading.

Usage:
  .venv/bin/modal run modal_compare_models.py --transcript-file ~/Desktop/t.txt
"""
import json
from pathlib import Path

import modal

BENCH = Path.home() / "bilal-dev/medadvisor-ane/tools/llm-benchmark"
RUBRIC = Path.home() / "bilal-dev/medadvisor-ane/rubrics/outpatient-clinic.json"
R = "/work"

app = modal.App("medadvisor-compare")

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
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
)

hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)

# Straight from Sources/LLMModel.swift. The 7B opens the assistant turn plainly;
# the 4B needs the pre-filled empty <think> block to suppress reasoning mode.
MODELS = [
    dict(name="Qwen 2.5-7B (ships today)",
         repo="bartowski/Qwen2.5-7B-Instruct-GGUF",
         file="Qwen2.5-7B-Instruct-Q4_K_M.gguf",
         opening="<|im_start|>assistant\n"),
    dict(name="Qwen 3.5-4B (the new one)",
         repo="bartowski/Qwen_Qwen3.5-4B-GGUF",
         file="Qwen_Qwen3.5-4B-Q4_K_M.gguf",
         opening="<|im_start|>assistant\n<think>\n\n</think>\n\n"),
]


@app.function(image=image, gpu="A10G", timeout=3000,
              volumes={"/root/.cache/huggingface": hf_cache})
def compare(transcript: str) -> dict:
    import subprocess, sys, time, requests
    sys.path.insert(0, R)
    from app_scoring import build_prompt, parse_criterion
    from huggingface_hub import hf_hub_download

    criteria = json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]
    out = {}

    for m in MODELS:
        gguf = hf_hub_download(m["repo"], m["file"])
        # n_ctx 6144 matches LlamaContext.swift, so the transcript is treated
        # exactly as the app treats it.
        log = open("/tmp/srv.log", "w+")
        srv = subprocess.Popen(
            ["/llama.cpp/build/bin/llama-server", "-m", gguf, "-c", "6144",
             "-ngl", "99", "--port", "8080", "--host", "127.0.0.1", "-t", "8"],
            stdout=log, stderr=subprocess.STDOUT)
        ready = False
        for _ in range(300):
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
            raise RuntimeError(f"server failed for {m['name']}\n{log.read()[-1500:]}")

        rows, t0 = [], time.time()
        for c in criteria:
            full = (f"<|im_start|>user\n{build_prompt(c, transcript)}"
                    f"<|im_end|>\n{m['opening']}")
            raw = requests.post("http://127.0.0.1:8080/completion", timeout=240, json={
                "prompt": full, "n_predict": 180, "temperature": 0,
                "cache_prompt": True, "stop": ["<|im_end|>"]}).json().get("content", "")
            verdict, evidence = parse_criterion(raw, transcript)
            tip = ""
            for line in raw.splitlines():
                if line.strip().upper().startswith("TIP:"):
                    tip = line.split(":", 1)[1].strip()
            rows.append({"id": c["id"], "prompt": c["prompt"],
                         "verdict": verdict, "evidence": (evidence or "")[:200],
                         "tip": tip[:400]})
            print(f"[{m['name']}] {c['id']:<22} {verdict}", flush=True)
        srv.kill()
        out[m["name"]] = {"rows": rows, "seconds": time.time() - t0}
    return out


@app.local_entrypoint()
def main(transcript_file: str):
    text = Path(transcript_file).expanduser().read_text().strip()
    print(f"transcript: {len(text)} chars, {len(text.splitlines())} lines\n")
    res = compare.remote(text)

    names = list(res.keys())
    a, b = res[names[0]]["rows"], res[names[1]]["rows"]
    lines = ["=" * 78,
             "SAME TRANSCRIPT, BOTH MODELS",
             "=" * 78,
             f"{names[0]}: {res[names[0]]['seconds']:.0f}s   "
             f"{names[1]}: {res[names[1]]['seconds']:.0f}s", "",
             f"{'criterion':<22} {'7B':<9} {'4B':<9} agree?",
             "-" * 78]
    for x, y in zip(a, b):
        lines.append(f"{x['id']:<22} {x['verdict']:<9} {y['verdict']:<9} "
                     f"{'' if x['verdict'] == y['verdict'] else '<-- DIFFER'}")
    lines += ["", "=" * 78, "WHERE THEY DISAGREE — read these against the answer key",
              "=" * 78]
    for x, y in zip(a, b):
        if x["verdict"] == y["verdict"]:
            continue
        lines += [f"\n### {x['id']} — {x['prompt']}",
                  f"  {names[0]}: {x['verdict']}",
                  f"     evidence: {x['evidence'] or '(none)'}",
                  f"     tip: {x['tip'] or '(none)'}",
                  f"  {names[1]}: {y['verdict']}",
                  f"     evidence: {y['evidence'] or '(none)'}",
                  f"     tip: {y['tip'] or '(none)'}"]
    lines += ["", "=" * 78,
              "EVERY TIP, BOTH MODELS — the part no metric measures",
              "=" * 78]
    for x, y in zip(a, b):
        if not (x["tip"] or y["tip"]):
            continue
        lines += [f"\n### {x['id']}",
                  f"  7B ({x['verdict']}): {x['tip'] or '(none)'}",
                  f"  4B ({y['verdict']}): {y['tip'] or '(none)'}"]
    text_out = "\n".join(lines)
    (BENCH / "results" / "MODEL-COMPARE.txt").write_text(text_out)
    print("\n" + text_out)
