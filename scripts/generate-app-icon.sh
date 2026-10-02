#!/bin/bash
# Regenerate the bundled macOS icon from the Paper-exported 1024px master.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/assets/icon/GuitarCozy.png"
iconset="$root/build/GuitarCozy.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$root/assets/icon/GuitarCozy.icns"
echo "Generated assets/icon/GuitarCozy.icns"
