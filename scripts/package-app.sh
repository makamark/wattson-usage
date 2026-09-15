#!/bin/bash
# scripts/package-app.sh — 打包 Swift 原生菜单栏 App（Wattson.app + DMG）。
#
# 命名沿用原版体系（与 0.1.0 发布的 Release 资产一致）：
#   App：   Wattson.app（Bundle ID com.wattson.app）
#   产物：  release/Wattson-<版本>-<架构>.dmg
#   版本：  Swift 原生线自 2.0.0 起（Electron 时代为 0.1.x）
#
# 用法：bash scripts/package-app.sh [版本号]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-2.0.24}"
PRODUCT="Wattson"
APP_ID="com.wattson.app"
ARCH="$(uname -m)"
OUT="$ROOT/release"
STAGE="$OUT/dmg-stage"

command -v swift >/dev/null 2>&1 || { echo "未找到 swift（需要 Xcode 或 Swift 工具链）"; exit 1; }
command -v iconutil >/dev/null 2>&1 || { echo "未找到 iconutil"; exit 1; }
[ -f docs/logo.png ] || { echo "缺少 docs/logo.png（图标源）"; exit 1; }

echo "[1/6] swift build -c release"
swift build -c release
BIN="$ROOT/.build/release/WattsonApp"
[ -x "$BIN" ] || { echo "构建产物缺失：$BIN"; exit 1; }
RES_BUNDLE="$ROOT/.build/release/Wattson_WattsonApp.bundle"
[ -d "$RES_BUNDLE" ] || { echo "构建产物缺失：$RES_BUNDLE"; exit 1; }

echo "[2/6] 组装 $PRODUCT.app"
APP="$OUT/$PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"

echo "[3/6] 内嵌 SwiftPM 资源束（brand.png / logos / mirror.sh）"
# 必须显式复制：SwiftPM 的 .bundle 不会自动进 .app，缺失时 AppResources 取不到资源，
# 品牌图标退化成兜底字形、远端同步不可用（旧版 Bundle.module 更是直接崩）。
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

echo "[4/6] 应用图标"
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

echo "[5/6] 写 Info.plist + 签名"
PLIST_VERSION="$VERSION" PLIST_APP_ID="$APP_ID" PLIST_PRODUCT="$PRODUCT" \
PLIST_MIN_OS="13.0" python3 - <<'PY'
import os
plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>{os.environ['PLIST_PRODUCT']}</string>
  <key>CFBundleDisplayName</key><string>Wattson</string>
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

echo "[6/6] 制作 DMG（含 Applications 拖拽快捷方式）"
mkdir -p "$STAGE"
rm -rf "$STAGE"/*
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$PRODUCT-$VERSION-$ARCH.dmg"
RAW="$OUT/$PRODUCT-tmp-raw.dmg"
rm -f "$DMG" "$RAW"

MOUNT=""
cleanup_dmg() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true; fi
  rm -f "$RAW" 2>/dev/null || true
}
trap cleanup_dmg EXIT

# 挂载前清掉历史遗留的同名卷：残留时系统会把新卷改名成「Wattson 1」，
# 于是 Finder 定位不到 disk "Wattson"，detach 也卸错目标而让后续 convert 失败
for stale in "/Volumes/$PRODUCT"*; do
  [ -d "$stale" ] && hdiutil detach "$stale" -force -quiet 2>/dev/null
done

# 先做可写镜像，mount 后用 Finder 排布图标（App 与 Applications 并排、大图标），再转压缩格式
hdiutil create -volname "$PRODUCT" -srcfolder "$STAGE" -ov -format UDRW "$RAW" >/dev/null
# 取实际挂载点（不用 /Volumes/$PRODUCT 硬编码，避免卷名被改写后卸不掉）
MOUNT="$(hdiutil attach "$RAW" -nobrowse | awk -v p="/$PRODUCT" '$NF ~ p {print $NF}' | tail -1)"
[ -n "$MOUNT" ] || { echo "挂载失败：$RAW"; exit 1; }
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
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
MOUNT=""
hdiutil convert "$RAW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RAW"
rm -rf "$STAGE"

echo "完成："
echo "  App：$APP"
echo "  DMG：$DMG"
echo "经即时通讯/AirDrop 分发的未签名包安装后需先：xattr -cr /Applications/$PRODUCT.app"
