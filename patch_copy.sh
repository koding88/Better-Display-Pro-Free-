#!/bin/bash
# Build a patched BetterDisplay copy that talks to our local licence server.
# Original /Applications/BetterDisplay.app is never modified.
#
#   bash patch_copy.sh
#   bash patch_copy.sh "/Applications/BetterDisplay Free.app"
#
# Tested with BetterDisplay 3.5.6 (build 40870), Paddle.framework 4.4.3.
set -euo pipefail
WS="$(cd "$(dirname "$0")" && pwd)"
SRC="${BD_SRC:-/Applications/BetterDisplay.app}"
DST="${1:-/Applications/BetterDisplay Free.app}"

if [ ! -d "$SRC" ]; then
  echo "!! BetterDisplay not found: $SRC" >&2
  exit 1
fi

SHORT="$(plutil -extract CFBundleShortVersionString raw "$SRC/Contents/Info.plist" 2>/dev/null || true)"
BUILD="$(plutil -extract CFBundleVersion raw "$SRC/Contents/Info.plist" 2>/dev/null || true)"
if [ "$SHORT" != "3.5.6" ] || [ "$BUILD" != "40870" ]; then
  echo "!! Unsupported BetterDisplay version: ${SHORT:-?} (${BUILD:-?})" >&2
  echo "   This patch is for 3.5.6 (40870). Install that exact version first." >&2
  exit 1
fi

echo "→ copy $SRC → $DST"
rm -rf "$DST"
ditto "$SRC" "$DST"
xattr -cr "$DST" 2>/dev/null || true

# Keep a copy of the original Paddle licence/product files + prefs.  The
# patched copy uses the same Paddle support folder, so activation will
# overwrite these.
SUPPORT="$HOME/Library/Application Support/BetterDisplay"
if [ -d "$SUPPORT" ]; then
  BACKUP="$WS/backup/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP"
  cp -p "$SUPPORT/762421.spadl" "$BACKUP/" 2>/dev/null || true
  cp -p "$SUPPORT/762421.padl" "$BACKUP/" 2>/dev/null || true
  defaults export pro.betterdisplay.BetterDisplay "$BACKUP/prefs.plist" 2>/dev/null || true
  echo "→ backup original licence/prefs → $BACKUP"
fi

echo "→ isolate preferences (same settings, separate domain)"
plutil -replace CFBundleIdentifier -string "pro.betterdisplay.BetterDisplay.free" "$DST/Contents/Info.plist"
TMP_PREFS="$(mktemp /tmp/bdprefs.XXXXXX.plist)"
if defaults export pro.betterdisplay.BetterDisplay "$TMP_PREFS" 2>/dev/null; then
  defaults import pro.betterdisplay.BetterDisplay.free "$TMP_PREFS" 2>/dev/null || true
fi
rm -f "$TMP_PREFS"

echo "→ patch binaries"
python3 "$WS/patch_binary.py" "$DST"

echo "→ build + inject anti-tamper neutraliser (libbdfree.dylib via Sparkle)"
# The loader dylib is loaded as a *declared* dependency (through Sparkle) so the
# app's anti-injection does not flag it.  Its constructor installs the selective
# hook on the Pro gate, patches the Sec* binding slots, and swizzles
# +[NSThread sleepForTimeInterval:] on the main thread to remove the beachball.
# See docs/anti-tamper-analysis.md.
LOADER_OUT="$DST/Contents/Frameworks/libbdfree.dylib"
clang -dynamiclib -arch arm64 -arch x86_64 -framework Foundation -framework Security \
  -install_name @rpath/libbdfree.dylib -o "$LOADER_OUT" \
  "$WS/loader/fishhook.c" "$WS/loader/libbdfree.m" "$WS/loader/hook.S"
python3 "$WS/inject_dylib.py" \
  "$DST/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
  "@rpath/libbdfree.dylib"

echo "→ re-sign ad-hoc"
cat > "$WS/copy_entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$LOADER_OUT" 2>&1 | tail -1
codesign --force --sign - "$DST/Contents/Frameworks/Paddle.framework" 2>&1 | tail -2
codesign --force --sign - "$DST/Contents/Frameworks/Sparkle.framework" 2>&1 | tail -1
codesign --force --deep --sign - --entitlements "$WS/copy_entitlements.plist" \
  "$DST" 2>&1 | tail -2
codesign --verify --deep --strict "$DST"
echo "OK — patched copy ready: $DST"
echo "     Run: ./keygen.command"
