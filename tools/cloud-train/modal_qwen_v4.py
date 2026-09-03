"""Fine-tune Qwen3.5-4B on the v4 (Bilal-standard) dataset — cloud GPU.

Same recipe as modal_qwen_v3.py, which produced the only fine-tune to beat
stock (+9.6 acc / -21.4 over on the 240 set, surviving Q4_K_M at 95.8%).
The ONLY variable changed is the data: v4 relabels to Bilal's grading standard
(grading_style.md — 11 rules from his 91 blind rulings) with new trap classes.
Recipe held fixed on purpose: if v4 wins, we know the data did it.

Inherited from v3 (each guard earned by a real failure):
  - bf16 HF transformers on NVIDIA; STOCK re-measured in this exact stack, so
    the decisive number is the in-stack stock-vs-tuned DELTA
  - prompt-masked loss (loss on the verdict tokens only)
  - every checkpoint screened on the HAND-WRITTEN 48 cases, never val loss
  - recall >= 80% hard floor (the reject-everything failure mode)
  - two learning rates in parallel containers (v3 winner was lr5e-5 step 180)

NEW in v4: after picking the winner, the job also grades the four CALIBRATION
transcripts (stock and tuned, same stack) and returns per-decision rows. The
local entrypoint writes them into calibration/judge-v4cloud[-stock]/ so the
DECISION metric — agreement with Bilal's held-out gold — is computed locally
by the audited calibration.py, never in the cloud:

    python ../llm-benchmark/calibration.py report --tag v4cloud
    python ../llm-benchmark/calibration.py report --tag v4cloud-stock

Pre-registered bars (2026-09-03, decided before any training):
  DECIDE  calibration gold: stock MLX single-pass 65.1%; stock + scoped
          verifier 84.1%; human band 85.7%. The adapter must clearly beat the
          in-stack stock calibration number AND land at/above ~84% to justify
          shipping weights over the free verifier. (Stack caveat: the final
          word belongs to the merged Q4_K_M GGUF — modal_gguf_eval.py,
          repointed at the v4 winner.)
  SELECT  48-case screen (selection only; max-over-checkpoints, not a result)
  REGRESS full 240 in-stack delta

PRIVACY: everything uploaded is authored fiction — generated transcripts,
hand-written test cases, LLM-drafted calibration transcripts, the rubric, and
the prompt builder. No recordings, no real consultations.

Usage (from tools/cloud-train, with `modal` installed and a token configured):
  modal run modal_qwen_v4.py
  modal run modal_qwen_v4.py --only-tag lr5e-5
"""
import json
import subprocess
import sys
from pathlib import Path

import modal

REPO = Path(__file__).resolve().parent.parent.parent
BENCH = REPO / "tools" / "llm-benchmark"
RUBRIC = REPO / "rubrics" / "outpatient-clinic.json"
CAL = BENCH / "calibration" / "transcripts"
R = "/work"

BASE_MODEL = "Qwen/Qwen3.5-4B"

app = modal.App("medadvisor-qwen35-v4")

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install("torch>=2.6", "transformers>=4.57", "peft>=0.14", "accelerate",
                 "datasets", "sentencepiece", "hf_transfer")
    .env({"HF_HUB_ENABLE_HF_TRANSFER": "1",
          "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True"})
    # add_local_* must come last: Modal rejects build steps after them.
    .add_local_file(str(BENCH / "app_scoring.py"), f"{R}/app_scoring.py")
    .add_local_file(str(BENCH / "realistic_cases.json"), f"{R}/realistic_cases.json")
    .add_local_file(str(BENCH / "data/scoring.json"), f"{R}/scoring.json")
    .add_local_file(str(RUBRIC), f"{R}/rubric.json")
    .add_local_file(str(BENCH / "data/finetune_v4/train.jsonl"), f"{R}/train.jsonl")
    .add_local_file(str(BENCH / "data/finetune_v4/valid.jsonl"), f"{R}/valid.jsonl")
    .add_local_dir(str(CAL), f"{R}/calibration")
)

hf_cache = modal.Volume.from_name("medadvisor-hf-cache", create_if_missing=True)
out_vol = modal.Volume.from_name("medadvisor-qwen-v4-out", create_if_missing=True)

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
    import torch
    sys.path.insert(0, R)
    from transformers import AutoTokenizer, AutoModelForCausalLM
    from peft import LoraConfig, get_peft_model
    from app_scoring import build_prompt, parse_criterion

    criteria = {c["id"]: c for c in json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]}
    crit_order = [c["id"] for c in json.loads(Path(f"{R}/rubric.json").read_text())["criteria"]]
    realistic = json.loads(Path(f"{R}/realistic_cases.json").read_text())
    snippets = json.loads(Path(f"{R}/scoring.json").read_text())
    cal = {p.stem: p.read_text().strip()
           for p in Path(f"{R}/calibration").glob("*.txt") if not p.stem.startswith("_")}

    print(f"[{tag}] torch {torch.__version__} cuda={torch.cuda.is_available()}", flush=True)
    tok = AutoTokenizer.from_pretrained(BASE_MODEL)
    tok.padding_side = "left"
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL, dtype=torch.bfloat16, device_map="cuda")

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

    def _generate(prompts, batch=8, max_new=180):
        outs = []
        prev_cache = model.config.use_cache
        model.config.use_cache = True
        for i in range(0, len(prompts), batch):
            chunk = prompts[i:i + batch]
            enc = tok([chat(p) for p in chunk], return_tensors="pt", padding=True).to("cuda")
            out = model.generate(**enc, max_new_tokens=max_new, do_sample=False,
                                 pad_token_id=tok.pad_token_id)
            for seq in out:
                outs.append(tok.decode(seq[enc["input_ids"].shape[1]:],
                                       skip_special_tokens=True))
        model.config.use_cache = prev_cache
        return outs

    @torch.no_grad()
    def score(cases, label) -> dict:
        model.eval()
        jobs = [(c["id"], cid, truth, c["flat"])
                for c in cases for cid, truth in c["labels"].items()]
        raws = _generate([build_prompt(criteria[cid], flat) for _, cid, _, flat in jobs])
        rows = []
        for (cse, cid, truth, flat), raw in zip(jobs, raws):
            pred, _ = parse_criterion(raw, flat)
            rows.append({"truth": truth, "pred": pred,
                         "correct": (pred == "met") == (truth == "met")})
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

    @torch.no_grad()
    def judge_calibration(label) -> dict:
        """Per-decision rows for the four calibration transcripts, in the same
        schema calibration.py's judge writes — the decision metric is computed
        LOCALLY against Bilal's gold, never here."""
        model.eval()
        jobs = [(tid, cid) for tid in sorted(cal) for cid in crit_order]
        raws = _generate([build_prompt(criteria[cid], cal[tid]) for tid, cid in jobs])
        rows = []
        for (tid, cid), raw in zip(jobs, raws):
            pred, ev = parse_criterion(raw, cal[tid])
            rows.append({"transcript": tid, "criterion": cid, "pred": pred,
                         "evidence": ev, "raw": raw[:400]})
        print(f"[{tag}] calibration rows generated: {label} ({len(rows)})", flush=True)
        return {tid: [r for r in rows if r["transcript"] == tid] for tid in sorted(cal)}

    # -- 1. stock baselines, measured in THIS stack -----------------------
    stock48 = score(realistic, "STOCK 48-case")
    cal_stock = judge_calibration("stock")

    # -- 2. train (prompt-masked loss — verdict tokens only) --------------
    rows = [json.loads(l) for l in open(f"{R}/train.jsonl")]
    examples, skipped = [], 0
    for r in rows:
        u, a = r["messages"][0]["content"], r["messages"][1]["content"]
        pids = tok(chat(u), add_special_tokens=False)["input_ids"]
        aids = tok(a + tok.eos_token, add_special_tokens=False)["input_ids"]
        ids = pids + aids
        if len(ids) > 1400:
            skipped += 1
            continue
        examples.append((ids, [-100] * len(pids) + aids))
    print(f"[{tag}] {len(examples)} training examples ({skipped} skipped as too long)", flush=True)

    model = get_peft_model(model, LoraConfig(
        r=16, lora_alpha=32, lora_dropout=0.05, task_type="CAUSAL_LM",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "gate_proj", "up_proj", "down_proj"]))
    model.print_trainable_parameters()
    model.gradient_checkpointing_enable()
    model.enable_input_require_grads()
    model.config.use_cache = False

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
            print(f"[{tag}] step {step:>3}/{TOTAL_STEPS}  loss {total:.4f}  "
                  f"peak {peak:.1f}GB", flush=True)
        if step % CKPT_EVERY == 0 or step == TOTAL_STEPS:
            d = f"/out/{tag}/step{step}"
            model.save_pretrained(d)
            checkpoints[step] = d

    # -- 3. screen every checkpoint on the HAND-WRITTEN cases (SELECT) ----
    screen, best, best_acc = [], None, -1.0
    for step, d in sorted(checkpoints.items()):
        model.load_adapter(d, adapter_name=f"s{step}")
        model.set_adapter(f"s{step}")
        m = score(realistic, f"step {step} 48-case")
        m["step"] = step
        screen.append(m)
        if m["acc"] > best_acc and m["recall"] >= RECALL_FLOOR:
            best_acc, best = m["acc"], step

    # -- 4. winner: 240 delta (REGRESS) + calibration rows (DECIDE) -------
    stock240 = tuned240 = cal_tuned = None
    if best is not None:
        with model.disable_adapter():
            stock240 = score(snippets, "STOCK 240")
        model.set_adapter(f"s{best}")
        tuned240 = score(snippets, f"step {best} 240")
        cal_tuned = judge_calibration(f"step {best}")
    else:
        print(f"[{tag}] NO checkpoint held recall >= {RECALL_FLOOR}% — "
              "skipping 240 and calibration", flush=True)

    out_vol.commit()
    return {"tag": tag, "lr": lr, "stock48": stock48, "screen": screen,
            "best_step": best, "stock240": stock240, "tuned240": tuned240,
            "cal_stock": cal_stock, "cal_tuned": cal_tuned}


def write_cal_rows(tag_dir: str, model_label: str, adapter: str, per_tid: dict):
    d = BENCH / "calibration" / tag_dir
    d.mkdir(parents=True, exist_ok=True)
    for tid, rows in per_tid.items():
        (d / f"{tid}.json").write_text(json.dumps(
            {"model": model_label, "no_think": True, "adapter": adapter,
             "rows": rows}, indent=2))
    print(f"calibration rows -> {d}/")


@app.local_entrypoint()
def main(only_tag: str = ""):
    # Contamination gate before anything is uploaded or paid for.
    gate = subprocess.run([sys.executable, str(BENCH / "check_overlap.py")])
    if gate.returncode != 0:
        raise SystemExit("contamination gate FAILED — fix the training data first")

    variants = [v for v in VARIANTS if not only_tag or v[0] == only_tag]
    print(f"Qwen3.5-4B v4 fine-tune on {GPU} — {len(variants)} variant(s) in parallel")
    print(f"cost ceiling ${BUDGET_USD:.2f} (timeout {TIMEOUT_S//60} min/container)\n")

    results = []
    for (tag, _), r in zip(variants, train_and_eval.starmap(variants, return_exceptions=True)):
        if isinstance(r, Exception):
            print(f"!! {tag} FAILED: {type(r).__name__}: {r}")
        else:
            results.append(r)
    if not results:
        raise SystemExit("all variants failed — see the Modal logs above")

    out = BENCH / "results" / "V4-CLOUD-REPORT.txt"
    lines = ["=" * 72,
             "Qwen3.5-4B v4 fine-tune — Bilal-standard data (Modal A10G, bf16)",
             "=" * 72,
             "Recipe identical to the v3 winner; ONLY the data changed.",
             "48-case numbers SELECT the checkpoint (max over draws, not a result).",
             "The DECISION is agreement with Bilal's calibration gold, computed",
             "locally: python ../llm-benchmark/calibration.py report --tag v4cloud",
             "Bars: stock-MLX 65.1% / stock+scoped-verifier 84.1% / human 85.7%.", ""]
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
                      f"over {t['over']-s['over']:+5.1f}   recall {t['recall']-s['recall']:+5.1f}"]
        else:
            lines += ["", f"  NO checkpoint held recall >= {RECALL_FLOOR}%."]
        lines.append("")

    # Calibration rows from the best surviving variant (highest tuned-240 acc).
    winners = [r for r in results if r["tuned240"]]
    if winners:
        w = max(winners, key=lambda r: r["tuned240"]["acc"])
        write_cal_rows("judge-v4cloud-stock", f"{BASE_MODEL} (bf16 cloud)", None,
                       w["cal_stock"])
        write_cal_rows("judge-v4cloud", f"{BASE_MODEL} (bf16 cloud)",
                       f"{w['tag']}/step{w['best_step']}", w["cal_tuned"])
        lines += [f"Calibration rows written from {w['tag']} step {w['best_step']}.",
                  "DECIDE locally:",
                  "  python ../llm-benchmark/calibration.py report --tag v4cloud-stock",
                  "  python ../llm-benchmark/calibration.py report --tag v4cloud",
                  "",
                  "If the bar is met: repoint modal_gguf_eval.py at this winner to",
                  "merge, quantise to Q4_K_M, and re-measure the shipping GGUF."]

    text = "\n".join(lines)
    out.write_text(text)
    print("\n" + text)
    print(f"report -> {out}")
