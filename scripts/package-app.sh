#!/bin/bash
# scripts/package-app.sh — 打包 Swift 原生菜单栏 App（WattsonNative.app + DMG）。
#
# 命名体系与 Electron 时代（Wattson / com.wattson.app / Wattson-<ver>-arm64.dmg）
# 明确区分：
#   App：   WattsonNative.app（Bundle ID com.wattson.native）
#   产物：  release/WattsonNative-<版本>-<架构>.dmg
#   版本：  2.x（Swift 原生产品线，参数化，默认 2.0.0）
#
# 用法：bash scripts/package-app.sh [版本号]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-2.0.9}"
PRODUCT="WattsonNative"
APP_ID="com.wattson.native"
ARCH="$(uname -m)"
OUT="$ROOT/release"
STAGE="$OUT/dmg-stage"

command -v swift >/dev/null 2>&1 || { echo "未找到 swift（需要 Xcode 或 Swift 工具链）"; exit 1; }
command -v iconutil >/dev/null 2>&1 || { echo "未找到 iconutil"; exit 1; }
[ -f docs/logo.png ] || { echo "缺少 docs/logo.png（图标源）"; exit 1; }

echo "[1/5] swift build -c release"
swift build -c release
BIN="$ROOT/.build/release/WattsonApp"
[ -x "$BIN" ] || { echo "构建产物缺失：$BIN"; exit 1; }

echo "[2/5] 组装 $PRODUCT.app"
APP="$OUT/$PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"

echo "[3/5] 应用图标"
# 最新图标：assets/icon.icns（原工程最新应用图标，含 trayTemplate 未用）；
# 缺失时回退用 docs/logo.png 现生成
if [ -f assets/icon.icns ]; then
  cp assets/icon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  ICONSET="$OUT/$PRODUCT.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -z "$s" "$s" docs/logo.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$d" "$d" docs/logo.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "[4/5] 写 Info.plist + 签名"
PLIST_VERSION="$VERSION" PLIST_APP_ID="$APP_ID" PLIST_PRODUCT="$PRODUCT" \
PLIST_MIN_OS="13.0" python3 - <<'PY'
import os
plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>{os.environ['PLIST_PRODUCT']}</string>
  <key>CFBundleDisplayName</key><string>Wattson Native</string>
  <key>CFBundleIdentifier</key><string>{os.environ['PLIST_APP_ID']}</string>
  <key>CFBundleExecutable</key><string>{os.environ['PLIST_PRODUCT']}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>{os.environ['PLIST_VERSION']}</string>
  <key>CFBundleVersion</key><string>{os.environ['PLIST_VERSION']}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>{os.environ['PLIST_MIN_OS']}</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
"""
with open("release/%s.app/Contents/Info.plist" % os.environ['PLIST_PRODUCT'], "w") as f:
    f.write(plist)
PY
codesign --force -s - "$APP"

echo "[5/5] 制作 DMG（含 Applications 拖拽快捷方式）"
mkdir -p "$STAGE"
rm -rf "$STAGE"/*
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$PRODUCT-$VERSION-$ARCH.dmg"
RAW="$OUT/$PRODUCT-tmp-raw.dmg"
rm -f "$DMG" "$RAW"
# 先做可写镜像，mount 后用 Finder 排布图标（App 与 Applications 并排、大图标），再转压缩格式
hdiutil create -volname "$PRODUCT" -srcfolder "$STAGE" -ov -format UDRW "$RAW" >/dev/null
MOUNT="/Volumes/$PRODUCT"
hdiutil attach "$RAW" -nobrowse -quiet
osascript <<OSA
tell application "Finder"
  -- 等待 Finder 识别新挂载的卷（最多 10s）
  repeat with i from 1 to 20
    if exists disk "$PRODUCT" then exit repeat
    delay 0.5
  end repeat
  tell disk "$PRODUCT"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {180, 120, 700, 420}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 88
    set position of item "$PRODUCT" of container window to {140, 120}
    set position of item "Applications" of container window to {380, 120}
    close
    open
  end tell
end tell
OSA
sleep 2
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RAW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RAW"
rm -rf "$STAGE"

echo "完成："
echo "  App：$APP"
echo "  DMG：$DMG"
echo "经即时通讯/AirDrop 分发的未签名包安装后需先：xattr -cr /Applications/$PRODUCT.app"
