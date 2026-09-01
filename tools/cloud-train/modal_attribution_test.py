"""How accurately does each model label WHO SPOKE each chunk?

Purity measurement (tools/llm-benchmark/test_speaker_split.py) showed the app's
sentence-splitter is already 99.2% pure across three real recordings -- 120 of
121 chunks contain exactly one speaker. So the mangled speaker labels in those
transcripts are NOT a segmentation problem. The classifier is mislabelling clean,
unambiguous chunks and the merge step then glues them to their neighbours, which
is what makes the damage visible as "the doctor's line attributed to the patient".

Concretely: "How bad, one to 10." sat alone in its own chunk and was labelled
Patient. The app's own prompt lists "how bad" as a strong DOCTOR signal.

This runs the app's REAL attribution prompt (PromptBuilder.speakerAttributionPrompt,
ported verbatim in app_scoring.build_attribution_prompt) over the numbered chunks
from each transcript, and scores per-chunk against hand-aligned ground truth.

Reported per model:
  accuracy      -- share of chunks labelled correctly
  D->P / P->D   -- direction of error. Doctor-lines-called-Patient is the damaging
                   one: the rubric asks "did the CLINICIAN do X", so losing a
                   doctor line can silently fail a criterion the doctor met.
  unlabelled    -- chunks the model skipped; the app inherits the previous
                   speaker for these, so they are not free.
"""
from pathlib import Path

import modal

BENCH = Path.home() / "bilal-dev/medadvisor-ane/tools/llm-benchmark"
R = "/work"

app = modal.App("medadvisor-attribution")

image = (
    modal.Image.from_registry("nvidia/cuda:12.8.1-devel-ubuntu24.04",
                              add_python="3.11")
    .apt_install("git", "build-essential", "cmake", "curl", "libcurl4-openssl-dev")
    .pip_install("requests", "huggingface_hub", "hf_transfer")
    .run_commands(
        "git clone --depth 1 https://github.com/ggml-org/llama.cpp /llama.cpp",
        "cmake -S /llama.cpp -B /llama.cpp/build -DGGML_CUDA=ON -DLLAMA_CURL=OFF "
        "-DCMAKE_CUDA_ARCHITECTURES=86 -DCMAKE_BUILD_TYPE=Release",
        "cmake --build /llama.cpp/build --config Release -j 8 --target llama-server",
        gpu="A10G",
    )
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(BENCH / "test_speaker_split.py"), f"{R}/splitdata.py")
)

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


@app.function(image=image, gpu="A10G", timeout=2400)
def run() -> dict:
    import subprocess, sys, time, re, requests
    sys.path.insert(0, R)
    from app_scoring import build_attribution_prompt
    from splitdata import TRANSCRIPTS, split_current
    from huggingface_hub import hf_hub_download

    # Rebuild chunks + ground truth exactly as the purity test does.
    cases = {}
    for name, frags in TRANSCRIPTS.items():
        text = " ".join(t for _, t in frags)
        owner = []
        for spk, frag in frags:
            owner.extend(spk * len(frag))
            owner.append(" ")
        owner = owner[:len(text)]
        chunks, truth = [], []
        for a, b in split_current(text):
            spk = {c for c in owner[a:b] if c in "DP"}
            if len(spk) != 1:
                continue                      # skip the single mixed chunk
            chunks.append(text[a:b].strip())
            truth.append(spk.pop())
        cases[name] = (chunks, truth)

    out = {}
    for m in MODELS:
        gguf = hf_hub_download(m["repo"], m["file"])
        log = open("/tmp/s.log", "w+")
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
            raise RuntimeError(f"server failed for {m['name']}\n{log.read()[-1200:]}")

        per_case = {}
        for name, (chunks, truth) in cases.items():
            prompt = build_attribution_prompt(chunks)
            full = f"<|im_start|>user\n{prompt}<|im_end|>\n{m['opening']}"
            raw = requests.post("http://127.0.0.1:8080/completion", timeout=300, json={
                "prompt": full, "n_predict": len(chunks) * 6 + 48,
                "temperature": 0, "stop": ["<|im_end|>"]}).json().get("content", "")
            # Same parse shape as PromptBuilder.parseAttribution: "N: D"
            pred = [None] * len(chunks)
            for line in raw.splitlines():
                mm = re.match(r'\s*(\d+)\s*[:.\)]\s*([DP])', line.strip(), re.I)
                if mm:
                    i = int(mm.group(1)) - 1
                    if 0 <= i < len(chunks):
                        pred[i] = mm.group(2).upper()
            correct = sum(1 for p, t in zip(pred, truth) if p == t)
            d_as_p = [c for p, t, c in zip(pred, truth, chunks) if t == "D" and p == "P"]
            p_as_d = sum(1 for p, t in zip(pred, truth) if t == "P" and p == "D")
            per_case[name] = dict(
                n=len(chunks), correct=correct, acc=correct / len(chunks) * 100,
                d_as_p=len(d_as_p), p_as_d=p_as_d,
                unlabelled=sum(1 for p in pred if p is None),
                examples=[c[:95] for c in d_as_p[:4]])
            print(f"[{m['name']}] {name:<10} {correct}/{len(chunks)} "
                  f"= {per_case[name]['acc']:.1f}%", flush=True)
        srv.kill()
        out[m["name"]] = per_case
    return out


@app.local_entrypoint()
def main():
    res = run.remote()
    lines = ["=" * 78,
             "SPEAKER-LABEL ACCURACY on 3 real recordings (single-speaker chunks)",
             "=" * 78,
             "Chunks come from the app's own sentence-splitter; the prompt is the",
             "app's own attribution prompt. Ground truth is hand-aligned.",
             "",
             f"{'model':<26} {'transcript':<11} {'n':>4} {'acc':>7} {'D->P':>6} {'P->D':>6} {'none':>5}",
             "-" * 78]
    for model, cases in res.items():
        tn = tc = td = tp = 0
        for name, r in cases.items():
            lines.append(f"{model:<26} {name:<11} {r['n']:>4} {r['acc']:>6.1f}% "
                         f"{r['d_as_p']:>6} {r['p_as_d']:>6} {r['unlabelled']:>5}")
            tn += r["n"]; tc += r["correct"]; td += r["d_as_p"]; tp += r["p_as_d"]
        lines.append(f"{model:<26} {'ALL':<11} {tn:>4} {tc / tn * 100:>6.1f}% "
                     f"{td:>6} {tp:>6}")
        lines.append("")
    lines += ["=" * 78,
              "DOCTOR LINES CALLED PATIENT — the damaging direction",
              "=" * 78,
              "The rubric asks 'did the CLINICIAN do X'. A doctor line handed to the",
              "patient can silently fail a criterion the doctor actually met.", ""]
    for model, cases in res.items():
        for name, r in cases.items():
            for e in r["examples"]:
                lines.append(f"  [{model.split()[1]}] {name}: \"{e}\"")
    text = "\n".join(lines)
    (BENCH / "results" / "ATTRIBUTION-REAL.txt").write_text(text)
    print("\n" + text)
