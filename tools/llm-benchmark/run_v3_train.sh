#!/bin/bash
# v3 fine-tune of Qwen3.5-4B — detached, survives closing the chat.
#
# Bar to beat: 85.4% accuracy / 31.2% over-score / 100% recall (STOCK, no training).
# Six earlier fine-tunes all scored BELOW their untrained baseline, so a run that
# merely "trains fine" is not a success. The stock number is printed in the report
# next to every checkpoint so the comparison cannot be dodged.
#
# Guards against the two failures that actually happened:
#   collapse to a constant answer  -> checkpoint every 60 iters, score EVERY one
#   synthetic val loss looked great while the model learned a positional shortcut
#                                  -> screen on the HAND-WRITTEN cases, not val loss
#
# Low LR (5e-6, vs 1e-5 before) and 8 layers because the failure mode was the
# model overwriting good judgment, not failing to fit.
set -u
cd "$(dirname "$0")"
PY=.venv/bin/python
MODEL=mlx-community/Qwen3.5-4B-4bit
OUT=adapters/qwen35-4b-v3
LOG=results/V3-RUN.log
REPORT=results/V3-REPORT.txt
mkdir -p results "$OUT"

say() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

say "=== v3 fine-tune: Qwen3.5-4B ==="
say "train 1015 / valid 134 · 1120 distinct doctor lines · labels 47/14/39"
say "BAR TO BEAT (stock, untrained): acc 85.4%  over 31.2%  recall 100%"

# ---------------------------------------------------------------- train
say "training (400 iters, lr 5e-6, 8 layers, checkpoint every 60)…"
$PY -m mlx_lm lora \
  --model "$MODEL" \
  --train \
  --data data/finetune_v3 \
  --adapter-path "$OUT" \
  --iters 400 \
  --batch-size 1 \
  --num-layers 8 \
  --learning-rate 5e-6 \
  --steps-per-report 20 \
  --steps-per-eval 60 \
  --save-every 60 \
  --max-seq-length 1280 \
  >> "$LOG" 2>&1
RC=$?

# 1280, not 3072: the longest example in this dataset is 1199 tokens, so 1280
# truncates nothing while reserving ~2.4x less memory. The first attempt asked
# for 3072 and the kernel SIGKILLed it on this 16GB machine.
if [ $RC -ne 0 ]; then
  if [ $RC -ge 128 ]; then
    say "TRAINING KILLED (signal $((RC-128))) — almost certainly out of memory."
    say "  free memory and retry, or drop --max-seq-length / --num-layers"
  else
    say "TRAINING FAILED (exit $RC) — see $LOG"
  fi
  exit 1
fi
say "training done"

# ------------------------------------------------- screen every checkpoint
{
  echo "==================================================================="
  echo "v3 FINE-TUNE — Qwen3.5-4B          started $(date '+%Y-%m-%d %H:%M')"
  echo "==================================================================="
  echo "Data fixes vs v1/v2: 1120 distinct doctor lines (was ~150), STT-style"
  echo "mess + mislabelled speakers, length tied to consultation quality,"
  echo "labels 47/14/39 (eval set is ~53/47)."
  echo
  echo "STOCK, UNTRAINED (the bar):   acc  85.4%   over  31.2%   recall 100.0%"
  echo "-------------------------------------------------------------------"
  echo "48-case realistic screen — hand-written cases, NOT synthetic val loss:"
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
  # Pick on accuracy, but refuse anything that gutted recall — that is the
  # Gemma failure mode: reject everything, look strict, become useless.
  if [ -n "${ACC:-}" ] && [ -n "${REC:-}" ] \
     && awk "BEGIN{exit !($ACC > $BESTACC && $REC >= 80)}"; then
    BESTACC=$ACC; BEST=$CK
  fi
done

# ------------------------------------------------ full 240 on the winner
{
  echo
  echo "STOCK on the same 48-case screen:  acc 89.6%  over 16.7%  recall 100.0%"
  echo "-------------------------------------------------------------------"
} >> "$REPORT"

if [ -z "$BEST" ]; then
  say "no checkpoint kept recall >= 80% — nothing worth a 240 run"
  echo "NO CHECKPOINT PASSED the recall>=80% floor. Training hurt the model" >> "$REPORT"
  echo "again; stock Qwen3.5-4B remains the best option." >> "$REPORT"
else
  say "best = $BEST (acc $BESTACC) — running full 240-decision set…"
  cp "$BEST" "$OUT/adapters.safetensors"
  echo "FULL 240-decision set, best checkpoint $(basename "$BEST"):" >> "$REPORT"
  $PY bench_scoring.py --model "$MODEL" --adapter-path "$OUT" --no-think 2>>"$LOG" \
    | tee -a "$LOG" | grep -E "^(accuracy|over-score|recall)" >> "$REPORT"
  {
    echo
    echo "COMPARE (same 240 set):"
    echo "  Qwen3.5-4B stock              acc  85.4%   over  31.2%   recall 100.0%"
    echo "  Qwen3.5-4B + verification     acc  90.0%   over  11.6%   recall  91.4%"
    echo "  Qwen2.5-7B ships today        acc  79.2%   over  36.6%   recall  93.0%"
  } >> "$REPORT"
fi

echo "" >> "$REPORT"
echo "FINISHED $(date '+%Y-%m-%d %H:%M')" >> "$REPORT"
say "=== ALL DONE — report: $REPORT ==="
