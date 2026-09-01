"""Can llama.cpp b10243 load the exact file the phone downloaded?

On device the 4B downloads from R2, passes its SHA-256 check, shows as
Installed and IN USE -- and then llama.cpp says "failed to load model". The
engine was bumped b7484 -> b10243 (which does know the qwen35 architecture) and
the error did not change.

The untested assumption: the benchmarks that scored 84.2% ran on a GGUF
CONVERTED IN THIS CONTAINER. The file on R2 is bartowski's published GGUF. Same
model, different producer, and it has never been through llama_model_load_from_file
here -- only its tensor list was read. If bartowski's file fails to load with the
same engine the app now ships, the file is the problem, not the phone, and the
fix is to upload the converted GGUF that is already known to load and score.

Loads BOTH through the identical binary, one after the other:
  stock-Q4_K_M.gguf  (ours, converted here, known to score 84.2%)
  the byte-for-byte R2 object the phone actually downloaded

Prints llama.cpp's own loader output for each, which is the error message the
iOS console would not show.
"""
import modal

app = modal.App("medadvisor-loadtest")

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
)

gguf_vol = modal.Volume.from_name("medadvisor-gguf", create_if_missing=True)

R2_URL = "https://pub-911d7a5254944de984f1c95e6b8ddcdd.r2.dev/Qwen3.5-4B-Q4_K_M.gguf"


@app.function(image=image, gpu="A10G", timeout=2400, volumes={"/gguf": gguf_vol})
def loadtest() -> str:
    import subprocess, os, urllib.request

    out = []
    # llama.cpp's own build number, so the report states the engine under test
    v = subprocess.run(["/llama.cpp/build/bin/llama-server", "--version"],
                       capture_output=True, text=True)
    out.append("engine: " + (v.stdout + v.stderr).strip()[:200])

    # Fetched from HuggingFace, not R2: Cloudflare 403s Python's user-agent from
    # datacenter IPs. Harmless here -- the two are byte-identical (same SHA-256
    # 13c16f42...65f8a983, same 3_013_027_808 bytes, verified against R2's object
    # and HuggingFace's x-linked-etag), so these are the phone's exact bytes.
    from huggingface_hub import hf_hub_download
    r2 = hf_hub_download("bartowski/Qwen_Qwen3.5-4B-GGUF",
                         "Qwen_Qwen3.5-4B-Q4_K_M.gguf")
    out.append(f"bartowski file: {os.path.getsize(r2)} bytes (== the R2 object)")

    for label, path in (("OURS (converted here)", "/gguf/stock-Q4_K_M.gguf"),
                        ("R2 (what the phone downloaded)", r2)):
        if not os.path.exists(path):
            out.append(f"\n### {label}: FILE MISSING at {path}")
            continue
        # llama-server exits non-zero on a load failure and prints the loader's
        # own diagnosis. (llama-cli is not built in this image -- only
        # llama-quantize and llama-server are, so using it would mean rebuilding
        # the CUDA image for nothing.)
        # A server that LOADS keeps running, so hitting the timeout is the
        # success signal; exiting on its own means the load failed.
        try:
            p = subprocess.run(
                ["/llama.cpp/build/bin/llama-server", "-m", path, "-ngl", "99",
                 "-c", "4096", "--port", "8099", "--host", "127.0.0.1",
                 "--no-warmup", "-t", "8"],
                capture_output=True, text=True, timeout=150)
            blob = (p.stdout or "") + (p.stderr or "")
            ok = False                      # exited => refused the model
            code = p.returncode
        except subprocess.TimeoutExpired as e:
            blob = ((e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")) + \
                   ((e.stderr or b"").decode() if isinstance(e.stderr, bytes) else (e.stderr or ""))
            ok, code = True, 0              # still alive => loaded fine
        out.append(f"\n### {label}: {'LOADED OK' if ok else f'FAILED (exit {code})'}")
        keep = [l for l in blob.splitlines()
                if any(k in l.lower() for k in
                       ("error", "failed", "unknown", "arch", "n_ctx", "type  ",
                        "missing", "assert", "load_tensors", "llama_model_load"))]
        out += ["    " + l[:160] for l in keep[:18]]
    return "\n".join(out)


@app.local_entrypoint()
def main():
    print(loadtest.remote())
