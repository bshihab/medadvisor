"""Fine-tune Qwen3.5-4B on the v3 dataset — on a cloud GPU, not the Mac mini.

WHY CLOUD, and this is not a preference:
Two attempts to run this locally ended in a KERNEL PANIC on the mini, both with
the identical signature —

    panic: "pending memory object unexpectedly found in non pending hash"
           @IOGPUGroupMemory.cpp:528

That is a bug inside Apple's GPU memory driver (macOS 25.3.0) that MLX's Metal
buffer churn during LoRA training reliably trips. It hard-reboots the machine
with no warning and no graceful failure. The mini is administered over SSH from
another state, so a panic means it stays down until someone physically reboots
it. No local GPU training. If a container falls over, only a container falls over.

WHAT IS MEASURED, and why the baseline is re-run here:
The 85.4% bar was measured with MLX 4-bit on Apple Silicon. This runs HF
transformers bf16 on an NVIDIA GPU — different quantisation, different kernels,
different numerics. Comparing a cloud fine-tune against a Metal baseline would
be measuring the stack, not the training. So STOCK is re-scored in this exact
container, and the number that decides anything is the DELTA between stock and
tuned measured here. Both are reported.

Guards carried over from the local design, each earned by a failure:
- every checkpoint is scored, not just the last  (v2 collapsed to a constant
  answer somewhere between iter 100 and 200)
- screening uses the HAND-WRITTEN cases, never synthetic validation loss (a
  previous adapter scored perfectly on synthetic data while quietly learning
  "utterance 1 = Patient")
- a checkpoint whose recall falls below 80% is refused outright, however good
  its accuracy looks (the Gemma failure: reject everything, look strict, be
  useless)

PRIVACY: what leaves the Mac is authored fiction — synthetic transcripts from
gen_finetune_v3.py, the hand-written test cases, the rubric, and the app's
prompt builder. No recordings, no patient content, no real consultations.

Usage:
  .venv/bin/modal run modal_qwen_v3.py
  .venv/bin/modal run modal_qwen_v3.py --only-tag lr5e-5
"""
import json
from pathlib import Path

import modal

BENCH = Path.home() / "bilal-dev/medadvisor-ane/tools/llm-benchmark"
RUBRIC = Path.home() / "bilal-dev/medadvisor-ane/rubrics/outpatient-clinic.json"
R = "/work"

BASE_MODEL = "Qwen/Qwen3.5-4B"

app = modal.App("medadvisor-qwen35-v3")

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install("torch>=2.6", "transformers>=4.57", "peft>=0.14", "accelerate",
                 "datasets", "sentencepiece", "hf_transfer")
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1",
          # Qwen3.5's gated-delta-rule layers allocate in awkward sizes; without
          # this the allocator fragments and dies asking for 16MB with 22GB in use.
          "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True"})
    # add_local_* must come last: Modal rejects build steps after them.
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(BENCH / "realistic_cases.json"), f"{R}/realistic_cases.json")
    .add_local_file(str(BENCH / "data/scoring.json"), f"{R}/scoring.json")
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
    .add_local_file(str(BENCH / "data/finetune_v3/train.jsonl"), f"{R}/train.jsonl")
    .add_local_file(str(BENCH / "data/finetune_v3/valid.jsonl"), f"{R}/valid.jsonl")
)

hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)
out_vol = modal.Volume.from_name("medadvisor-qwen-v3-out", create_if_missing=True)

# Two learning rates. The local run used 5e-6, but that was tuned for MLX's LoRA
# on a 4-bit model; peft LoRA on bf16 with r=16 normally wants 1e-4-ish. Rather
# than guess once and burn the run on a bad rate, try a gentle and a standard
# one in parallel — they are independent containers, so this costs wall-clock
# nothing and halves the chance of a wasted experiment.
VARIANTS = [("lr5e-5", 5e-5), ("lr2e-4", 2e-4)]

BUDGET_USD = 6.00
GPU = "A10G"
GPU_HOURLY_USD = 1.10
TIMEOUT_S = int(BUDGET_USD / (GPU_HOURLY_USD * len(VARIANTS)) * 3600)

CKPT_EVERY = 60
TOTAL_STEPS = 400
RECALL_FLOOR = 80.0


@app.function(image=image, gpu=GPU, timeout=TIMEOUT_S,
              volumes={"/root/.cache/huggingface": hf_cache, "/out": out_vol})
def train_and_eval(tag: str, lr: float) -> dict:
    import sys, torch
    sys.path.insert(0, R)
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from peft import LoraConfig, get_peft_model
    from app_scoring import build_prompt, parse_criterion

    criteria = {c["id"]: c for c in json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]}
    realistic = json.loads(Path(f"{R}/realistic_cases.json").read_text())
    snippets = json.loads(Path(f"{R}/scoring.json").read_text())

    print(f"[{tag}] torch {torch.__version__} cuda={torch.cuda.is_available()}", flush=True)
    tok = AutoTokenizer.from_pretrained(BASE_MODEL)
    tok.padding_side = "left"
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL, dtype=torch.bfloat16, device_map="cuda")

    def chat(prompt: str) -> str:
        """The app suppresses Qwen3.5's reasoning mode. Without it the model
        emits a long 'Thinking Process:' block and never reaches a verdict
        inside the token budget — measured: 1 of 21 utterances labelled."""
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
    def score(cases, label, batch=8) -> dict:
        model.eval()
        # Training turns use_cache off (incompatible with gradient checkpointing).
        # Generating without a KV cache is ruinously slow, so turn it back on for
        # scoring and restore it afterwards.
        prev_cache = model.config.use_cache
        model.config.use_cache = True
        jobs = [(c["id"], cid, truth, c["flat"])
                for c in cases for cid, truth in c["labels"].items()]
        rows = []
        for i in range(0, len(jobs), batch):
            chunk = jobs[i:i + batch]
            texts = [chat(build_prompt(criteria[cid], flat)) for _, cid, _, flat in chunk]
            enc = tok(texts, return_tensors="pt", padding=True).to("cuda")
            out = model.generate(**enc, max_new_tokens=180, do_sample=False,
                                 pad_token_id=tok.pad_token_id)
            for (cse, cid, truth, flat), seq in zip(chunk, out):
                raw = tok.decode(seq[enc["input_ids"].shape[1]:], skip_special_tokens=True)
                pred, _ = parse_criterion(raw, flat)
                rows.append({"case": cse, "criterion": cid, "truth": truth, "pred": pred,
                             "correct": (pred == "met") == (truth == "met")})
        model.config.use_cache = prev_cache
        n = len(rows)
        missed = [r for r in rows if r["truth"] == "missed"]
        met = [r for r in rows if r["truth"] == "met"]
        m = dict(label=label, n=n,
                 acc=sum(r["correct"] for r in rows) / n * 100,
                 over=sum(r["pred"] == "met" for r in missed) / len(missed) * 100 if missed else 0.0,
                 recall=sum(r["pred"] == "met" for r in met) / len(met) * 100 if met else 0.0)
        print(f"[{tag}] {label:<22} acc {m['acc']:5.1f}%  over {m['over']:5.1f}%  "
              f"recall {m['recall']:5.1f}%  (n={n})", flush=True)
        return m

    # -- 1. stock baseline, measured in THIS stack ------------------------
    stock48 = score(realistic, "STOCK 48-case")

    # -- 2. train ---------------------------------------------------------
    rows = [json.loads(l) for l in open(f"{R}/train.jsonl")]
    examples = []
    for r in rows:
        u, a = r["messages"][0]["content"], r["messages"][1]["content"]
        prompt = chat(u)
        pids = tok(prompt, add_special_tokens=False)["input_ids"]
        aids = tok(a + tok.eos_token, add_special_tokens=False)["input_ids"]
        ids = pids + aids
        if len(ids) > 1400:
            continue
        # Mask the prompt: loss only on the verdict the model must produce.
        examples.append((ids, [-100] * len(pids) + aids))
    print(f"[{tag}] {len(examples)} training examples", flush=True)

    model = get_peft_model(model, LoraConfig(
        r=16, lora_alpha=32, lora_dropout=0.05, task_type="CAUSAL_LM",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "gate_proj", "up_proj", "down_proj"]))
    model.print_trainable_parameters()

    # Gradient checkpointing is not optional here. Qwen3.5 uses gated-delta-rule
    # (linear attention) layers, and without flash-linear-attention/causal-conv1d
    # installed transformers falls back to a torch implementation that keeps far
    # more activations alive. The first attempt OOM'd inside
    # torch_chunk_gated_delta_rule with 21.67GB of 22GB allocated — inference was
    # fine, only the backward pass blew up. Recomputing activations costs ~30%
    # speed and cuts activation memory roughly 5x.
    model.gradient_checkpointing_enable()
    model.enable_input_require_grads()   # else checkpointing sees no grad path
    model.config.use_cache = False       # incompatible with checkpointing

    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=lr)
    sched = torch.optim.lr_scheduler.OneCycleLR(
        opt, max_lr=lr, total_steps=TOTAL_STEPS, pct_start=0.1)

    import random
    rng = random.Random(0)
    order = list(range(len(examples)))
    rng.shuffle(order)
    ACC_STEPS = 4
    checkpoints = {}
    model.train()
    for step in range(1, TOTAL_STEPS + 1):
        opt.zero_grad()
        total = 0.0
        for _ in range(ACC_STEPS):
            if not order:
                order = list(range(len(examples)))
                rng.shuffle(order)
            ids, labels = examples[order.pop()]
            t = torch.tensor([ids], device="cuda")
            lab = torch.tensor([labels], device="cuda")
            loss = model(input_ids=t, labels=lab).loss / ACC_STEPS
            loss.backward()
            total += loss.item()
        torch.nn.utils.clip_grad_norm_(
            [p for p in model.parameters() if p.requires_grad], 1.0)
        opt.step()
        sched.step()
        if step == 1 or step % 20 == 0:
            peak = torch.cuda.max_memory_allocated() / 2**30
            cap = torch.cuda.get_device_properties(0).total_memory / 2**30
            print(f"[{tag}] step {step:>3}/{TOTAL_STEPS}  loss {total:.4f}  "
                  f"peak {peak:.1f}/{cap:.1f}GB", flush=True)
        if step % CKPT_EVERY == 0 or step == TOTAL_STEPS:
            d = f"/out/{tag}/step{step}"
            model.save_pretrained(d)
            checkpoints[step] = d

    # -- 3. screen every checkpoint on the HAND-WRITTEN cases -------------
    screen, best, best_acc = [], None, -1.0
    for step, d in sorted(checkpoints.items()):
        model.load_adapter(d, adapter_name=f"s{step}")
        model.set_adapter(f"s{step}")
        m = score(realistic, f"step {step} 48-case")
        m["step"] = step
        screen.append(m)
        # Accuracy alone is not enough: a model that rejects everything scores
        # well on over-scoring and is useless. Recall floor is a hard gate.
        if m["acc"] > best_acc and m["recall"] >= RECALL_FLOOR:
            best_acc, best = m["acc"], step

    # -- 4. the decisive comparison, on the full 240 ----------------------
    stock240 = tuned240 = None
    if best is not None:
        with model.disable_adapter():
            stock240 = score(snippets, "STOCK 240")
        model.set_adapter(f"s{best}")
        tuned240 = score(snippets, f"step {best} 240")
    else:
        print(f"[{tag}] NO checkpoint held recall >= {RECALL_FLOOR}% — "
              "skipping the 240 run", flush=True)

    out_vol.commit()
    return {"tag": tag, "lr": lr, "stock48": stock48, "screen": screen,
            "best_step": best, "stock240": stock240, "tuned240": tuned240}


@app.local_entrypoint()
def main(only_tag: str = ""):
    variants = [v for v in VARIANTS if not only_tag or v[0] == only_tag]
    print(f"Qwen3.5-4B v3 fine-tune on {GPU} — {len(variants)} variant(s) in parallel")
    print(f"cost ceiling ${BUDGET_USD:.2f} (timeout {TIMEOUT_S//60} min/container); "
          f"expected actual ~$1.50\n")

    results = []
    for (tag, _), r in zip(variants, train_and_eval.starmap(variants, return_exceptions=True)):
        if isinstance(r, Exception):
            print(f"!! {tag} FAILED: {type(r).__name__}: {r}")
        else:
            results.append(r)
    if not results:
        raise SystemExit("all variants failed — see the Modal logs above")

    out = BENCH / "results" / "V3-CLOUD-REPORT.txt"
    lines = ["=" * 72,
             "Qwen3.5-4B v3 fine-tune (Modal A10G, HF transformers bf16)",
             "=" * 72,
             "Stock is re-measured in THIS stack; the local 85.4% was MLX 4-bit on",
             "Metal, so only the stock-vs-tuned delta below is a fair comparison.", ""]
    for r in results:
        lines += [f"--- {r['tag']} (lr={r['lr']}) ---",
                  f"  {'STOCK 48-case':<20} acc {r['stock48']['acc']:5.1f}%  "
                  f"over {r['stock48']['over']:5.1f}%  recall {r['stock48']['recall']:5.1f}%"]
        for m in r["screen"]:
            flag = "  <- best" if m["step"] == r["best_step"] else ""
            lines.append(f"  {'step ' + str(m['step']):<20} acc {m['acc']:5.1f}%  "
                         f"over {m['over']:5.1f}%  recall {m['recall']:5.1f}%{flag}")
        if r["tuned240"]:
            s, t = r["stock240"], r["tuned240"]
            lines += ["",
                      f"  FULL 240 — stock       acc {s['acc']:5.1f}%  over {s['over']:5.1f}%  recall {s['recall']:5.1f}%",
                      f"  FULL 240 — tuned       acc {t['acc']:5.1f}%  over {t['over']:5.1f}%  recall {t['recall']:5.1f}%",
                      f"  DELTA                  acc {t['acc']-s['acc']:+5.1f}   "
                      f"over {t['over']-s['over']:+5.1f}   recall {t['recall']-s['recall']:+5.1f}",
                      "",
                      "  VERDICT: " + ("training HELPED" if t["acc"] > s["acc"]
                                       else "training HURT — ship the untrained model")]
        else:
            lines += ["", f"  NO checkpoint held recall >= {RECALL_FLOOR}% — training hurt."]
        lines.append("")
    text = "\n".join(lines)
    out.write_text(text)
    print("\n" + text)
    print(f"report -> {out}")
