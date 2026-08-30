"""Train the strict-grader adapter on a cloud GPU via Modal, then benchmark it.

Why cloud: the full 569-example x 2-epoch run is ~15h on the 16GB mini (swap-
bound at ~95s/step). On one 24GB Ampere GPU it is ~10-20 min, so we can afford
TWO learning-rate variants in parallel and keep the better adapter.

Design notes:
- Apple's toolkit resolves its weights as `PROJECT_ROOT/assets` where
  PROJECT_ROOT is the parent of `examples/` (utils.py:26). So the code lands at
  /toolkit/{examples,export} and the Volume mounts at /toolkit/assets.
- The Volume holds ONLY the bf16 base checkpoint + tokenizer/configs (6.5GB).
  The 186MB draft model is skipped: we train no draft model.
- `--precision bf16` is REQUIRED: the fp32 base checkpoint was deleted locally,
  and our patched load_base_model (mmap + assign=True) only kicks in for bf16.
- Privacy: the training data is authored fiction (see gen_adapter_dataset.py).
  What leaves the Mac is Apple's toolkit weights + synthetic text. No patient
  content, no transcripts, nothing from the app.

Usage:
  modal run modal_train.py                      # both variants, parallel
  modal run modal_train.py --only-tag lr1e-3    # one variant
"""
import json
import subprocess
from pathlib import Path

import modal

LOCAL_TOOLKIT = Path.home() / "bilal-dev/medadvisor-ane/tools/adapter-training/adapter_training_toolkit_v26_0_0"
LOCAL_BENCH = Path.home() / "bilal-dev/medadvisor-ane/tools/llm-benchmark"
LOCAL_DATA = LOCAL_BENCH / "data" / "adapter"

REMOTE_TOOLKIT = "/toolkit"
REMOTE_ASSETS = f"{REMOTE_TOOLKIT}/assets"
REMOTE_DATA = "/data"
REMOTE_OUT = "/out"

app = modal.App("medadvisor-strict-grader")

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install(
        "torch>=2.6",
        "tamm~=0.1.0",
        "tqdm",
        "sentencepiece",
        "pydantic",
        "coremltools==8.3.0",
    )
    # Must precede every add_local_*: Modal rejects build steps after those.
    # Fragmentation was not the OOM cause, but expandable segments cost nothing
    # and give the allocator room to reuse the big logits buffers.
    .env({"PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True"})
    .add_local_dir(str(LOCAL_TOOLKIT / "examples"), f"{REMOTE_TOOLKIT}/examples")
    .add_local_dir(str(LOCAL_TOOLKIT / "export"), f"{REMOTE_TOOLKIT}/export")
    .add_local_file(str(LOCAL_DATA / "train.jsonl"), f"{REMOTE_DATA}/train.jsonl")
    .add_local_file(str(LOCAL_DATA / "valid.jsonl"), f"{REMOTE_DATA}/valid.jsonl")
    .add_local_file(str(LOCAL_DATA / "bench_prompts_dose48bal.jsonl"),
                    f"{REMOTE_DATA}/bench_prompts.jsonl")
)

# 6.5GB of Apple base-model assets, uploaded once and reused by every run.
assets_vol = modal.Volume.from_name("medadvisor-fm-assets", create_if_missing=True)
# Checkpoints + raw benchmark output, downloaded afterwards.
out_vol = modal.Volume.from_name("medadvisor-adapter-out", create_if_missing=True)

VARIANTS = [
    # (tag, learning_rate) — Apple's documented default, plus a gentler one.
    # The dose tests showed this model overcorrects hard, so the gentler rate is
    # a real contender, not a formality.
    ("lr1e-3", 1e-3),
    ("lr3e-4", 3e-4),
]

# --- cost ceiling ---------------------------------------------------------
# Modal bills per second of container time and this workspace has no
# server-side spend cap, so the ceiling is enforced HERE: the per-container
# timeout is derived from a dollar budget. A hung or runaway run dies at the
# budget instead of billing indefinitely.
#
# Expected real spend is ~$0.40 (both variants finish in ~20 min); this is the
# worst case, not the estimate. Lower BUDGET_USD to tighten it.
BUDGET_USD = 7.00
GPU = "A10G"
GPU_HOURLY_USD = 1.10          # Modal A10G list price — update if GPU changes
TIMEOUT_S = int(BUDGET_USD / (GPU_HOURLY_USD * len(VARIANTS)) * 3600)


def _run(cmd: list[str], label: str) -> str:
    """Run a toolkit command in /toolkit, streaming output to the Modal log."""
    print(f"\n=== {label} ===\n$ {' '.join(cmd)}", flush=True)
    proc = subprocess.run(cmd, cwd=REMOTE_TOOLKIT, capture_output=True, text=True)
    tail = (proc.stdout or "")[-3000:] + "\n" + (proc.stderr or "")[-3000:]
    print(tail, flush=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{label} failed (exit {proc.returncode})")
    return (proc.stdout or "") + "\n" + (proc.stderr or "")


@app.function(
    image=image,
    gpu=GPU,                         # Ampere: bf16-capable (T4/V100 are not)
    volumes={REMOTE_ASSETS: assets_vol, REMOTE_OUT: out_vol},
    timeout=TIMEOUT_S,               # budget-derived; see BUDGET_USD above
)
def train_and_bench(tag: str, learning_rate: float) -> dict:
    """Full 569-example training run, then generate the 48 held-out verdicts."""
    import torch

    print(f"[{tag}] torch {torch.__version__} | cuda={torch.cuda.is_available()} "
          f"| bf16_supported={torch.cuda.is_bf16_supported()}", flush=True)
    assert torch.cuda.is_available(), "no GPU visible"
    assert torch.cuda.is_bf16_supported(), "GPU lacks bf16 (need Ampere+)"

    ckpt_dir = f"{REMOTE_OUT}/checkpoints_{tag}"
    Path(ckpt_dir).mkdir(parents=True, exist_ok=True)

    _run([
        "python", "-m", "examples.train_adapter",
        "--train-data", f"{REMOTE_DATA}/train.jsonl",
        "--eval-data", f"{REMOTE_DATA}/valid.jsonl",
        "--precision", "bf16",
        # batch 4 OOM'd on a 24GB A10G: at ~1.4k-token prompts the logits
        # tensor (batch x seq x vocab) and its gradient dominate, ~21GB peak.
        # batch 1 x 4 accumulation steps = the same effective batch of 4 with a
        # quarter of the activation peak — and it is the shape already proven to
        # fit on the 16GB Mac.
        "--batch-size", "1",
        "--gradient-accumulation-steps", "4",
        "--epochs", "2",
        "--warmup-epochs", "1",          # gentle ramp — the dose tests had none
        "--learning-rate", str(learning_rate),
        "--activation-checkpointing",
        "--checkpoint-dir", ckpt_dir,
    ], f"[{tag}] train")

    final = f"{ckpt_dir}/adapter-final.pt"
    if not Path(final).exists():
        raise RuntimeError(f"[{tag}] no adapter-final.pt in {ckpt_dir}")

    raw = _run([
        "python", "-m", "examples.generate",
        "--prompt", f"{REMOTE_DATA}/bench_prompts.jsonl",
        "--checkpoint", final,
        "--precision", "bf16",
        "--temperature", "0",
        "--max-new-tokens", "180",
    ], f"[{tag}] bench")

    Path(f"{REMOTE_OUT}/bench_raw_{tag}.txt").write_text(raw)
    out_vol.commit()
    return {"tag": tag, "learning_rate": learning_rate, "raw": raw,
            "checkpoint": final}


@app.local_entrypoint()
def main(only_tag: str = ""):
    variants = [v for v in VARIANTS if not only_tag or v[0] == only_tag]
    print(f"launching {len(variants)} variant(s) in parallel: "
          f"{[t for t, _ in variants]}")
    print(f"cost ceiling ${BUDGET_USD:.2f} — {GPU} at ${GPU_HOURLY_USD:.2f}/hr, "
          f"per-container timeout {TIMEOUT_S // 60} min "
          f"(expected actual: ~$0.40)")

    # return_exceptions: one variant crashing must not discard the other's work.
    raw_results = list(train_and_bench.starmap(variants, return_exceptions=True))
    results = []
    for (tag, _), r in zip(variants, raw_results):
        if isinstance(r, Exception):
            print(f"!! {tag} FAILED: {type(r).__name__}: {r}")
        else:
            results.append(r)
    if not results:
        raise SystemExit("all variants failed — see the Modal logs above")

    outdir = LOCAL_BENCH / "results"
    outdir.mkdir(exist_ok=True)
    for r in results:
        p = outdir / f"cloud_bench_raw_{r['tag']}.txt"
        p.write_text(r["raw"])
        print(f"{r['tag']}: raw output -> {p}")
    print("\nNow score them locally with the app's own parser:\n"
          "  cd tools/llm-benchmark && .venv/bin/python score_cloud_raw.py")
