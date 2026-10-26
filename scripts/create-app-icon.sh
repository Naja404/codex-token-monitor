#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/codex-monitor-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$ROOT/.build/icon-tools" "$ROOT/Assets/AppIcon.iconset" "$WORK/AppIcon.iconset"
swiftc "$ROOT/Packaging/AppIcon.swift" \
  -module-cache-path "$ROOT/.build/icon-tools/ModuleCache" \
  -o "$ROOT/.build/icon-tools/AppIcon"
"$ROOT/.build/icon-tools/AppIcon" "$ROOT/Assets/AppIcon.png" "$WORK/master.png"

for logical in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""
    if [ "$scale" -eq 2 ]; then suffix="@2x"; fi
    pixels=$((logical * scale))
    sips -z "$pixels" "$pixels" "$WORK/master.png" \
      --out "$WORK/AppIcon.iconset/icon_${logical}x${logical}${suffix}.png" >/dev/null
  done
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"
cp "$WORK/AppIcon.iconset/"*.png "$ROOT/Assets/AppIcon.iconset/"
cp "$WORK/AppIcon.icns" "$ROOT/Assets/AppIcon.icns"
echo "Generated macOS app icon: $ROOT/Assets/AppIcon.icns"
