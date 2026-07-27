#!/bin/bash
# One-shot cloud training: upload Apple's base assets to a Modal Volume (once),
# train both LR variants on a GPU in parallel, pull back the raw verdicts, and
# score them locally with the app's own parser.
#
# Idempotent: the 6.5GB upload is skipped if the Volume already has the file.
set -euo pipefail

TOOLKIT="$HOME/bilal-dev/medadvisor-ane/tools/adapter-training/adapter_training_toolkit_v26_0_0"
CLOUD="$HOME/bilal-dev/medadvisor-ane/tools/cloud-train"
BENCH="$HOME/bilal-dev/medadvisor-ane/tools/llm-benchmark"
MODAL="$CLOUD/.venv/bin/modal"
VOL="medadvisor-fm-assets"

cd "$CLOUD"

echo "=== 1. Volume: $VOL ==="
$MODAL volume create "$VOL" 2>/dev/null || echo "(exists)"

if $MODAL volume ls "$VOL" 2>/dev/null | grep -q "base-model.bf16.pt"; then
  echo "base model already uploaded — skipping the 6.5GB transfer"
else
  echo "--- uploading small assets ---"
  for f in base-model-config.json draft-model-config.json tokenizer-config.json \
           checkpoint_spec.yaml tokenizer.model weights_template.bin draft.mil; do
    [ -f "$TOOLKIT/assets/$f" ] && $MODAL volume put "$VOL" "$TOOLKIT/assets/$f" "/$f" || true
  done
  echo "--- uploading base-model.bf16.pt (6.5GB, ~10 min at 108 Mbps) ---"
  $MODAL volume put "$VOL" "$TOOLKIT/assets/base-model.bf16.pt" "/base-model.bf16.pt"
fi

echo
echo "=== 2. Train both variants on GPU (parallel) ==="
$MODAL run modal_train.py

echo
echo "=== 3. Score locally with the app's parser ==="
cd "$BENCH" && .venv/bin/python score_cloud_raw.py
