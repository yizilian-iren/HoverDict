#!/bin/bash
#
# Package HoverDict.app into a distributable .dmg (drag-to-Applications layout).
#
# This produces a FREE (self-signed, NOT notarized) DMG. It works on other Macs, but
# because it isn't notarized, recipients must bypass Gatekeeper on first launch:
#   • GUI:        right-click HoverDict.app → Open → Open  (only needed once)
#   • or Terminal: xattr -dr com.apple.quarantine /Applications/HoverDict.app
#
# For a zero-warning "double-click and it just works" DMG you need a paid Apple
# Developer ID + notarization (see README → 分发).
#
set -euo pipefail

APP_NAME="HoverDict"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# 1) Build the signed .app first.
echo "==> Building app…"
./Scripts/build_app.sh >/dev/null

APP="$ROOT/build/$APP_NAME.app"
if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1")"
DMG="$ROOT/build/${APP_NAME}-${VERSION}.dmg"

# 2) Stage a folder with the app + an /Applications symlink (the classic drag layout).
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
echo "==> Staging DMG contents…"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3) Build a compressed DMG.
echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1)"
echo ""
echo "✅ Built: $DMG  ($SIZE)"
echo ""
echo "分发说明(因为未公证,收件人首次打开需绕过门禁):"
echo "  1) 把 DMG 发给对方;对方打开后把 HoverDict 拖进 Applications。"
echo "  2) 首次启动:右键点 HoverDict.app → 打开 → 再点“打开”(仅需一次)。"
echo "     若提示“已损坏”,在终端执行:"
echo "       xattr -dr com.apple.quarantine /Applications/HoverDict.app"
echo "  3) 首次会请求“屏幕录制”权限,按提示在 系统设置 中勾选后重启 App。"
