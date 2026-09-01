"""Why does our Qwen3.5 GGUF fail to load with 'missing tensor blk.32.attn_norm.weight'?

Two hypotheses, and they need opposite fixes:

  A. OUR CONVERSION is broken — the transformers save_pretrained round-trip in
     prepare() dropped or renamed tensors, so the GGUF is genuinely incomplete.
     Fix: convert straight from the original HF repo, no re-save.

  B. OUR llama.cpp IS THE PROBLEM — master has in-flight Qwen3.5 support where
     convert_hf_to_gguf.py and the runtime loader disagree about the hybrid
     (gated-delta-rule + full-attention) layer layout.
     Fix: pin llama.cpp to a release tag that shipped working Qwen3.5 support.

The discriminator: bartowski's published Qwen3.5-4B GGUF is known-good — it is
already on the Mac and is the file staged for R2. If it loads in OUR build, the
runtime is fine and the fault is ours (A). If it also fails, the build is too
old or too new for this architecture (B).

Cheap: no GPU, ~2 minutes.
"""
import modal

app = modal.App("medadvisor-gguf-diag")

image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("git")
    .pip_install("huggingface_hub", "hf_transfer", "gguf")
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1"})
)

gguf_vol = modal.Volume.from_name("medadvisor-gguf", create_if_missing=True)
hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)


@app.function(image=image, timeout=1200,
              volumes={"/gguf": gguf_vol, "/root/.cache/huggingface": hf_cache})
def diagnose() -> str:
    from gguf import GGUFReader
    out = []

    # What did OUR converter actually write around the failing layer?
    r = GGUFReader("/gguf/stock-f16.gguf")
    names = {t.name for t in r.tensors}
    out.append(f"our stock-f16.gguf: {len(names)} tensors")
    arch = None
    for f in r.fields.values():
        if f.name == "general.architecture":
            arch = bytes(f.parts[f.data[0]]).decode()
    out.append(f"  general.architecture = {arch}")
    for blk in (31, 32, 33):
        got = sorted(n.split(".", 2)[-1] for n in names if n.startswith(f"blk.{blk}."))
        out.append(f"  blk.{blk}: {got}")

    # And what does the known-good published file contain for the same layers?
    from huggingface_hub import hf_hub_download
    try:
        p = hf_hub_download("bartowski/Qwen_Qwen3.5-4B-GGUF",
                            "Qwen_Qwen3.5-4B-Q4_K_M.gguf")
        r2 = GGUFReader(p)
        names2 = {t.name for t in r2.tensors}
        out.append(f"\nbartowski Q4_K_M: {len(names2)} tensors")
        for blk in (31, 32, 33):
            got = sorted(n.split(".", 2)[-1] for n in names2 if n.startswith(f"blk.{blk}."))
            out.append(f"  blk.{blk}: {got}")
        only_theirs = sorted(names2 - names)[:15]
        only_ours = sorted(names - names2)[:15]
        out.append(f"\nin theirs, missing from ours ({len(names2-names)}): {only_theirs}")
        out.append(f"in ours, missing from theirs ({len(names-names2)}): {only_ours}")
    except Exception as e:
        out.append(f"\ncould not fetch reference GGUF: {type(e).__name__}: {e}")

    return "\n".join(out)


@app.local_entrypoint()
def main():
    print(diagnose.remote())
