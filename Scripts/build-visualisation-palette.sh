#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
xcrun -sdk macosx metal -std=metal3.0 -mmacosx-version-min=14.0 -c \
    "$ROOT/Sources/Stream64/Resources/SIDVisualizationPalette.metal" -o "$WORK/palette.air"
xcrun -sdk macosx metallib "$WORK/palette.air" \
    -o "$ROOT/Sources/Stream64/Resources/SIDVisualizationPalette.metallib"
