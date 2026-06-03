#!/bin/bash
#
# Build HoverDict.app from the SwiftPM executable, using only Command Line Tools
# (no full Xcode required), then code-sign it.
#
# Why a real .app bundle: the Screen Recording (TCC) permission is bound to an app's
# bundle id + code signature. A bare SwiftPM binary in .build would be attributed to
# the terminal, not to HoverDict, so the permission wouldn't stick. Always launch the
# generated .app — never the raw binary.
#
# Signing:
#   - By default we ad-hoc sign (codesign -s -). Good enough to run locally.
#     Caveat: ad-hoc identity is the binary's cdhash, so every rebuild changes it and
#     you may have to re-grant Screen Recording.
#   - To use a real cert instead (stable permission across rebuilds, path to notarization):
#       CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Scripts/build_app.sh
#     List candidates with:  security find-identity -v -p codesigning
#
set -euo pipefail

APP_NAME="HoverDict"
CONFIG="${CONFIG:-release}"

# Resolve repo root (parent of this script's dir), regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

echo "==> Building ($CONFIG) with swift build…"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

APP="$ROOT/build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Bundle the ECDICT dictionary (looked up at runtime via Bundle.main).
if [[ -f "$ROOT/Resources/ecdict.db" ]]; then
    cp "$ROOT/Resources/ecdict.db" "$APP/Contents/Resources/ecdict.db"
else
    echo "warning: Resources/ecdict.db not found — dictionary lookups will be disabled." >&2
fi

# Code sign.
# Priority: explicit CODESIGN_IDENTITY env > stable self-signed "HoverDict Dev"
#           (created by Scripts/create_signing_cert.sh) > ad-hoc ("-").
# Using the stable cert keeps the designated requirement constant across rebuilds, so
# the Screen Recording permission is granted ONCE and survives recompiles.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-certificate -c "HoverDict Dev" >/dev/null 2>&1; then
    IDENTITY="HoverDict Dev"
else
    IDENTITY="-"
fi
echo "==> Code signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" || true

echo ""
echo "✅ Built: $APP"
echo "   Run with:   open \"$APP\"     (or: make run)"
echo "   First run will request Screen Recording permission — grant it, then relaunch."
