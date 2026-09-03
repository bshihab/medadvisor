#!/bin/bash
# v4 fine-tune of Qwen3.5-4B on the Bilal-standard dataset — detached, survives
# closing the chat. Run on the Air in tools/llm-benchmark:
#   nohup ./run_v4_train.sh > results/V4-NOHUP.log 2>&1 &
#
# Pre-registered success bars (decided BEFORE training, 2026-09-03):
#   1. Calibration gold (the decision metric, held out, never trained on):
#      stock single-pass = 65.1%, stock + scoped verifier = 84.1%,
#      human inter-rater band = 85.7%.
#      The adapter must beat 84.1% SINGLE-PASS to justify shipping weights
#      instead of the verifier. 65-84% = no better than the free option.
#   2. 48-case realistic screen per checkpoint (recall floor 80% — the
#      collapse guard that caught v1/v2).
#   3. Corrected 240 set (regression check via audit_recompute.py; stock is
#      96.1% there — a big drop means the adapter learned the style, forgot
#      the task).
#
# Set roles (kept disjoint, verified by check_overlap.py before training):
#   TRAIN    data/finetune_v4 (generated)
#   SELECT   48-case realistic screen — picks the checkpoint; its winning
#            score is a screening statistic (max over ~7 draws), NOT a result
#   DECIDE   calibration gold — never used for selection, reported once
#   REGRESS  corrected 240 set
#
# SCOPE: this local MLX run is a DATA-VALIDATION GATE, not the ship artifact.
# The app runs GGUF via llama.cpp; an MLX LoRA on the 4-bit base does not
# reach it. If this run clears the bar, retrain on the cloud bf16 pipeline
# (tools/cloud-train/modal_qwen_v3.py pointed at data/finetune_v4), merge,
# export Q4_K_M, and RE-MEASURE the GGUF — the proven path with quantisation
# measured alongside (see results/V3-GGUF-REPORT.txt).
set -u
cd "$(dirname "$0")"
PY=.venv/bin/python
MODEL=mlx-community/Qwen3.5-4B-4bit
OUT=adapters/qwen35-4b-v4
LOG=results/V4-RUN.log
REPORT=results/V4-REPORT.txt
mkdir -p results "$OUT"

say() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

say "=== v4 fine-tune: Qwen3.5-4B on the Bilal-standard dataset ==="
say "regenerating data (deterministic, seed 29)…"
$PY gen_finetune_v4.py --transcripts 200 2>&1 | tee -a "$LOG"

say "contamination gate: training data vs eval sets…"
$PY check_overlap.py 2>&1 | tee -a "$LOG"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  say "CONTAMINATION GATE FAILED — training data overlaps an eval set. Aborting."
  exit 1
fi

say "token-length preflight: no example may exceed the training window…"
$PY - << 'PYEOF' 2>&1 | tee -a "$LOG"
import json, sys
from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained("mlx-community/Qwen3.5-4B-4bit")
mx = 0
for fn in ("train", "valid"):
    for line in open(f"data/finetune_v4/{fn}.jsonl"):
        mx = max(mx, len(tok.apply_chat_template(json.loads(line)["messages"], tokenize=True)))
print(f"longest example: {mx} tokens (window 1536)")
sys.exit(0 if mx < 1536 else 1)
PYEOF
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  say "TOKEN PREFLIGHT FAILED — an example would be truncated (and truncation cuts the LABEL off the end). Aborting."
  exit 1
fi

# Loss covers prompt+completion (mlx_lm default; v3 parity — v3 improved
# through this same path). If this run lands close-but-under the bar, lever #1
# before touching lr is completion-only loss: check support with
#   $PY -m mlx_lm lora --help | grep -i mask
# then add --mask-prompt and rerun. One variable at a time.
say "training (400 iters, lr 5e-6, 8 layers, checkpoint every 60)…"
$PY -m mlx_lm lora \
  --model "$MODEL" \
  --train \
  --data data/finetune_v4 \
  --adapter-path "$OUT" \
  --iters 400 \
  --batch-size 1 \
  --num-layers 8 \
  --learning-rate 5e-6 \
  --steps-per-report 20 \
  --steps-per-eval 60 \
  --save-every 60 \
  --max-seq-length 1536 \
  >> "$LOG" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  if [ $RC -ge 128 ]; then
    say "TRAINING KILLED (signal $((RC-128))) — almost certainly out of memory."
  else
    say "TRAINING FAILED (exit $RC) — see $LOG"
  fi
  exit 1
fi
say "training done"

{
  echo "==================================================================="
  echo "v4 FINE-TUNE — Bilal-standard data       started $(date '+%Y-%m-%d %H:%M')"
  echo "==================================================================="
  echo "DECISION BAR: calibration gold single-pass > 84.1% (stock+scoped"
  echo "verifier). Below that, the verifier ships and the adapter does not."
  echo
  echo "48-case realistic screen (recall floor 80%):"
} > "$REPORT"

BEST=""; BESTACC=0
for CK in $(ls "$OUT"/*_adapters.safetensors 2>/dev/null | sort -t/ -k3 -V) "$OUT/adapters.safetensors"; do
  [ -f "$CK" ] || continue
  STEP=$(basename "$CK" | sed 's/_adapters.safetensors//;s/adapters.safetensors/final/')
  say "scoring checkpoint $STEP …"
  cp "$CK" "$OUT/adapters.safetensors" 2>/dev/null
  R=$($PY bench_scoring.py --model "$MODEL" --adapter-path "$OUT" --no-think --realistic 2>>"$LOG" \
        | tee -a "$LOG" | grep -E "^(accuracy|over-score|recall)" | tr -s ' ')
  ACC=$(echo "$R" | grep accuracy | grep -oE '[0-9]+\.[0-9]+' | head -1)
  OVER=$(echo "$R" | grep over-score | grep -oE '[0-9]+\.[0-9]+' | head -1)
  REC=$(echo "$R" | grep recall | grep -oE '[0-9]+\.[0-9]+' | head -1)
  printf "  step %-6s acc %6s%%  over %6s%%  recall %6s%%\n" \
         "$STEP" "${ACC:-?}" "${OVER:-?}" "${REC:-?}" >> "$REPORT"
  say "  step $STEP -> acc ${ACC:-?} over ${OVER:-?} recall ${REC:-?}"
  if [ -n "${ACC:-}" ] && [ -n "${REC:-}" ] \
     && awk "BEGIN{exit !($ACC > $BESTACC && $REC >= 80)}"; then
    BESTACC=$ACC; BEST=$CK
  fi
done

if [ -z "$BEST" ]; then
  say "no checkpoint kept recall >= 80% — training hurt the model again"
  echo "NO CHECKPOINT PASSED the recall>=80% floor." >> "$REPORT"
  exit 0
fi

say "best = $BEST (48-case acc $BESTACC) — decision metric: calibration gold…"
cp "$BEST" "$OUT/adapters.safetensors"
{
  echo
  echo "Best checkpoint: $(basename "$BEST")  (48-case acc $BESTACC%)"
  echo "-------------------------------------------------------------------"
  echo "DECISION METRIC — calibration gold (held out):"
} >> "$REPORT"

$PY calibration.py judge  --adapter-path "$OUT" --tag v4 2>&1 | tee -a "$LOG" >/dev/null
$PY calibration.py verify --adapter-path "$OUT" --tag v4 2>&1 | tee -a "$LOG" >/dev/null
$PY calibration.py report --tag v4 2>&1 | tee -a "$LOG" | head -14 >> "$REPORT"

{
  echo
  echo "BARS: stock single-pass 65.1% · stock+scoped-verifier 84.1% · human band 85.7%"
  echo
  echo "Regression check — corrected 240 set (stock = 96.1%):"
} >> "$REPORT"
$PY bench_scoring.py --model "$MODEL" --adapter-path "$OUT" --no-think 2>>"$LOG" \
  | tee -a "$LOG" | grep -E "^(accuracy|over-score|recall)" >> "$REPORT"
echo "(re-score against corrected labels: $PY audit_recompute.py)" >> "$REPORT"

echo "" >> "$REPORT"
echo "FINISHED $(date '+%Y-%m-%d %H:%M')" >> "$REPORT"
say "=== ALL DONE — report: $REPORT ==="
