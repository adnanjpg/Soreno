#!/bin/bash
# Download Parakeet TDT 0.6B v2 CoreML models from HuggingFace.
# Safe to re-run: curl -C - resumes partial downloads.
set -euo pipefail

BASE_URL="https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/main"
DEST="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"

echo "Downloading Parakeet TDT 0.6B v2 models to:"
echo "  $DEST"
echo ""

# Model files to download (path relative to repo root)
FILES=(
    "Preprocessor.mlmodelc/coremldata.bin"
    "Preprocessor.mlmodelc/metadata.json"
    "Preprocessor.mlmodelc/model.mil"
    "Preprocessor.mlmodelc/analytics/coremldata.bin"
    "Preprocessor.mlmodelc/weights/weight.bin"
    "Encoder.mlmodelc/coremldata.bin"
    "Encoder.mlmodelc/metadata.json"
    "Encoder.mlmodelc/model.mil"
    "Encoder.mlmodelc/analytics/coremldata.bin"
    "Encoder.mlmodelc/weights/weight.bin"
    "Decoder.mlmodelc/coremldata.bin"
    "Decoder.mlmodelc/metadata.json"
    "Decoder.mlmodelc/model.mil"
    "Decoder.mlmodelc/analytics/coremldata.bin"
    "Decoder.mlmodelc/weights/weight.bin"
    "JointDecision.mlmodelc/coremldata.bin"
    "JointDecision.mlmodelc/metadata.json"
    "JointDecision.mlmodelc/model.mil"
    "JointDecision.mlmodelc/analytics/coremldata.bin"
    "JointDecision.mlmodelc/weights/weight.bin"
    "parakeet_vocab.json"
)

for file in "${FILES[@]}"; do
    out="$DEST/$file"
    mkdir -p "$(dirname "$out")"
    echo ">>> $file"
    curl -L -C - --retry 10 --retry-delay 5 -o "$out" "$BASE_URL/$file"
done

echo ""
echo "Done! Models saved to: $DEST"
