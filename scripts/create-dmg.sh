#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 || ! -d "$1/Contents/MacOS" ]]; then
  echo "Usage: $0 '/path/Codex Token Monitor.app' '/path/installer.dmg'" >&2
  exit 1
fi

APP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
mkdir -p "$(dirname "$2")"
OUTPUT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DMG_PYTHON=${DMG_PYTHON:-python3}
if ! "$DMG_PYTHON" -c 'import dmgbuild' 2>/dev/null; then
  echo "Install packaging dependencies: python3 -m pip install -r Packaging/requirements-dmg.txt" >&2
  echo "For a virtual environment, set DMG_PYTHON to its Python executable." >&2
  exit 1
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/codex-installer.XXXXXX")
MOUNT="$WORK/mount"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$MOUNT" -quiet || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$MOUNT"
swift -module-cache-path "$WORK/module-cache" "$ROOT/Packaging/DMGBackground.swift" "$WORK/install.png"
# dmgbuild writes Finder layout records directly; no Apple Events or desktop session is needed.
"$DMG_PYTHON" -m dmgbuild -s "$ROOT/Packaging/dmg-settings.py" \
  -D "app=$APP" -D "background=$WORK/install.png" \
  "Codex Token Monitor" "$WORK/final.dmg"
hdiutil verify -quiet "$WORK/final.dmg"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$WORK/final.dmg"
MOUNTED=1
test -s "$MOUNT/.DS_Store"
"$DMG_PYTHON" - "$MOUNT/.DS_Store" <<'PY'
import sys
from ds_store import DSStore

with DSStore.open(sys.argv[1], "r") as layout:
    assert layout["Codex Token Monitor.app"]["Iloc"] == (190, 240), "App position is missing"
    assert layout["Applications"]["Iloc"] == (530, 240), "Applications position is missing"
    assert layout["."]["icvp"]["backgroundType"] == 2, "Installer background is missing"
    assert not layout["."]["bwsp"]["ShowSidebar"], "Installer sidebar should be hidden"
PY
test "$(readlink "$MOUNT/Applications")" = /Applications
codesign --verify --deep --strict "$MOUNT/Codex Token Monitor.app"
hdiutil detach -quiet "$MOUNT"
MOUNTED=0
mv "$WORK/final.dmg" "$OUTPUT"
echo "Installer created: $OUTPUT"
