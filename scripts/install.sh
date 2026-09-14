#!/bin/bash
# scripts/install.sh — 构建全部组件并安装两个 LaunchAgent（从 agg.config.json 派生配置）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOME/codeburn-agg"  # server/mirror 日志目录（launchd 不建父目录）

NODE="$(command -v node)" || { echo "未找到 node（需要 ≥22.13）"; exit 1; }
if ! "$NODE" -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=13)?0:1)'; then
  echo "node 版本过低（需要 ≥22.13，当前 $("$NODE" --version)）"; exit 1
fi

if [ ! -f "$ROOT/agg.config.json" ]; then
  echo "缺少 $ROOT/agg.config.json — 先运行: bash scripts/setup.sh（或参照 agg.config.example.json 手写）"
  exit 1
fi
PORT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("server",{}).get("port",8317))' "$ROOT/agg.config.json" 2>/dev/null || echo 8317)"

echo "[1/6] codeburn 构建与依赖"
(cd "$ROOT/codeburn" && npm ci && npm run build)
echo "[2/6] server 依赖"
(cd "$ROOT/server" && npm ci)
echo "[3/6] web 构建"
(cd "$ROOT/web" && npm ci && npm run build)
echo "[4/6] 生成 devices.json（codeburn 多设备根）"
python3 "$ROOT/scripts/gen-config.py"
echo "[5/6] 首次镜像同步（大文件，耐心等待）"
# mirror.sh 失败/跳过会以非零退出：装服务不等数据——警告并继续，装好后可手动补同步
if ! bash "$ROOT/sync/mirror.sh"; then
  echo "  警告：本轮镜像有设备未完成（见上方日志），可稍后手动执行: bash $ROOT/sync/mirror.sh"
fi
echo "[6/6] 安装 LaunchAgents（渲染模板）"
mkdir -p ~/Library/LaunchAgents
for t in "$ROOT"/templates/*.plist.template; do
  sed -e "s|@@ROOT@@|$ROOT|g" -e "s|@@NODE@@|$NODE|g" -e "s|@@HOME@@|$HOME|g" "$t" \
    > ~/Library/LaunchAgents/"$(basename "$t" .plist.template)".plist
done
launchctl unload ~/Library/LaunchAgents/com.wattson.mirror.plist 2>/dev/null || true
launchctl unload ~/Library/LaunchAgents/com.wattson.server.plist 2>/dev/null || true
# 旧命名（≤2026-09-14 Wattson 更名前）的遗留服务与 plist：卸载并清理
for legacy in com.mark.codeburn-agg-mirror com.mark.codeburn-agg-server com.usage-viewer.mirror com.usage-viewer.server; do
  launchctl unload ~/Library/LaunchAgents/${legacy}.plist 2>/dev/null || true
  rm -f ~/Library/LaunchAgents/${legacy}.plist
done
# 只停「占着我们目标端口」的进程：按端口定位（lsof），不再按宽泛命令文本
# pkill -f——后者会误杀其它项目里恰好同名的进程
PIDS="$(lsof -ti tcp:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  echo "  端口 $PORT 被占用（pid: $(echo "$PIDS" | tr '\n' ' ')），停止旧实例"
  kill $PIDS 2>/dev/null || true
  sleep 1
fi
launchctl load ~/Library/LaunchAgents/com.wattson.mirror.plist || true
launchctl load ~/Library/LaunchAgents/com.wattson.server.plist || true
# load 已加载时报错也不中止：兜底强制重启 server（mirror 靠 StartInterval 自跑）
launchctl kickstart -k "gui/$(id -u)/com.wattson.server" 2>/dev/null || true

# 成功边界 = 服务健康检查通过：冷启动全量解析可能数分钟，轮询 /api/status
echo "等待聚合服务就绪（冷启动首次解析可能需要数分钟）…"
DEADLINE=$((SECONDS + 360))
until curl -fsS "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "失败：${PORT} 端口 6 分钟内未就绪。查看日志: ~/codeburn-agg/server.log"
    exit 1
  fi
  sleep 5
done
echo "完成：http://127.0.0.1:${PORT}（健康检查通过）"
