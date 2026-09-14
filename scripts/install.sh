#!/bin/bash
# scripts/install.sh — Swift 构建 + 首次镜像 + 安装两个 LaunchAgent（从 agg.config.json 派生配置）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOME/wattson"  # server/mirror 日志目录（launchd 不建父目录）

command -v swift >/dev/null 2>&1 || { echo "未找到 swift（需要 Xcode 或 Swift 工具链）"; exit 1; }

if [ ! -f "$ROOT/agg.config.json" ]; then
  echo "缺少 $ROOT/agg.config.json — 先运行: bash scripts/setup.sh（或参照 agg.config.example.json 手写）"
  exit 1
fi
PORT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("server",{}).get("port",8317))' "$ROOT/agg.config.json" 2>/dev/null || echo 8317)"

echo "[1/4] swift build -c release（首次构建需数分钟）"
(cd "$ROOT" && swift build -c release)
BIN="$ROOT/.build/release"
[ -x "$BIN/wattson-server" ] || { echo "构建产物缺失：$BIN/wattson-server"; exit 1; }

echo "[2/4] 生成 devices.json（多设备镜像根）"
python3 "$ROOT/scripts/gen-config.py"

echo "[3/4] 首次镜像同步（大文件，耐心等待）"
# mirror.sh 失败/跳过会以非零退出：装服务不等数据——警告并继续，装好后可手动补同步
if ! bash "$ROOT/sync/mirror.sh"; then
  echo "  警告：本轮镜像有设备未完成（见上方日志），可稍后手动执行: bash $ROOT/sync/mirror.sh"
fi

echo "[4/4] 安装 LaunchAgents（渲染模板）"
mkdir -p ~/Library/LaunchAgents
for t in "$ROOT"/templates/*.plist.template; do
  sed -e "s|@@ROOT@@|$ROOT|g" -e "s|@@BIN@@|$BIN|g" -e "s|@@HOME@@|$HOME|g" "$t" \
    > ~/Library/LaunchAgents/"$(basename "$t" .plist.template)".plist
done
launchctl unload ~/Library/LaunchAgents/com.wattson.mirror.plist 2>/dev/null || true
launchctl unload ~/Library/LaunchAgents/com.wattson.server.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.wattson.mirror.plist
launchctl load ~/Library/LaunchAgents/com.wattson.server.plist

echo "安装完成。等待服务就绪（首次冷启动约 1–2 分钟）…"
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/api/status"; then
    echo "就绪：http://127.0.0.1:${PORT}  日志: ~/wattson/{server,mirror}.log"
    exit 0
  fi
  sleep 6
done
echo "失败：${PORT} 端口 6 分钟内未就绪。查看日志: ~/wattson/server.log"
exit 1
