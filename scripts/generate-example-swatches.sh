#!/bin/bash
# generate-example-swatches.sh
#
# One-off helper to pre-generate PNG swatches and badges for example colors
# referenced in install-nm-lockscreen-colors.sh.
#
# - Swatch: 2560x1440 PNG
# - Badge:  128x128  PNG
# - Output: ./swatches (or first arg path)
#
# Requires: ImageMagick `convert`

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need_cmd convert

OUT_DIR="${1:-./swatches}"
mkdir -p "$OUT_DIR"
chmod 755 "$OUT_DIR"

# Colors mentioned in installer prompts and examples
# Name           Hex
colors=(
  "green=#0e6625"
  "blue=#00529b"
  "red=#b20021"
  "orange=#ff8c00"
  "purple=#6a0dad"
  "gold=#c9a227"
  "gray=#808080"
  "blue2=#0b61a4"   # from non-interactive usage example
)

make_img() {
  local hex="$1" out="$2" size="$3"
  convert -size "$size" "xc:${hex}" "$out"
  chmod 644 "$out"
}

printf "Generating example swatches into %s\n" "$OUT_DIR"
for entry in "${colors[@]}"; do
  name="${entry%%=*}"
  hex="${entry#*=}"
  swatch_path="$OUT_DIR/${name}.png"
  badge_path="$OUT_DIR/${name}_logo.png"

  printf "  - %-8s %s -> %s, %s\n" "$name" "$hex" "$swatch_path" "$badge_path"
  make_img "$hex" "$swatch_path" 2560x1440
  make_img "$hex" "$badge_path"   128x128
done

printf "Done. %d colors written to %s\n" "${#colors[@]}" "$OUT_DIR" 