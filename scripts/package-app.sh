#!/bin/bash
# scripts/package-app.sh — 构建并打包菜单栏客户端 Wattson（产物在 app/release/：
# mac-arm64/Wattson.app 未打包目录 + Wattson-<版本>-arm64.dmg 分发镜像）。
# 打包内容：Electron 壳 + dist（主进程/小窗/向导）+ server + codeburn + web/dist + sync（extraResources，
# 不进 asar，tsx 按真实路径解析）。打包态不依赖系统 Node：server 由 Electron 内置 Node 托管。
# 注意：打包会重建 app/release，若客户端正在本目录运行请先退出。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1/5] codeburn 构建与依赖"; (cd "$ROOT/codeburn" && npm ci && npm run build)
echo "[2/5] server 依赖（含 tsx，打包态运行时依赖 devDependencies）"; (cd "$ROOT/server" && npm ci)
echo "[3/5] web 构建"; (cd "$ROOT/web" && npm ci && npm run build)
echo "[4/5] app 依赖"; (cd "$ROOT/app" && npm ci)
echo "[5/5] electron-builder（dmg，附未打包 .app）"; (cd "$ROOT/app" && npm run dist:dmg)
echo "完成:"
echo "  $ROOT/app/release/mac-arm64/Wattson.app"
ls "$ROOT/app/release/"*.dmg 2>/dev/null || true
