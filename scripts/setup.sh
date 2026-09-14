#!/bin/bash
# scripts/setup.sh — 交互式初始化：探测工具 → 配置远端设备 → 生成 agg.config.json/devices.json → 可选安装
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/agg.config.json"
LOCAL_NAME="$(hostname -s)"

say() { echo "== $*"; }
ask() { printf '%s' "$1"; read -r REPLY; }

# ---- 参数解析（非交互模式） ----
SSH_LIST="" PORT=8317 REFRESH=30 ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh) SSH_LIST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --refresh) REFRESH="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    *) echo "未知参数: $1（用法: setup.sh [--ssh 别名或别名:设备名,...] [--port N] [--refresh M] [--yes]）"; exit 1 ;;
  esac
done

# ---- 本机工具探测 ----
say "检测本机数据源"
LOCAL_TOOLS=()
[ -e "$HOME/.zcode/cli/db/db.sqlite" ] && LOCAL_TOOLS+=(zcode)
[ -d "$HOME/.codex/sessions" ] && LOCAL_TOOLS+=(codex)
[ -e "$HOME/.workbuddy/workbuddy.db" ] && LOCAL_TOOLS+=(workbuddy)
echo "  本机($LOCAL_NAME): ${LOCAL_TOOLS[*]:-无}"
if [ ${#LOCAL_TOOLS[@]} -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  ask "本机未发现任何工具数据源，仍继续？[y/N] "; [ "$REPLY" = "y" ] || exit 1
fi

# ---- 远端设备收集 ----
# 设备名默认取别名；别名与设备名不同时用「别名:设备名」指定（设备名=镜像目录名与看板「设备」维度值）
# 校验口径与 app/src/config.ts、sync/mirror.sh 一致：名称限 [A-Za-z0-9._-]，
# SSH 别名限 [A-Za-z0-9._@%:+-] 且不以 - 开头（防 shell 元字符/选项注入）。
declare -a DEV_NAMES=() DEV_SSH=()
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$ ]]; }
valid_ssh() { case "$1" in -*) return 1 ;; esac; [[ "$1" =~ ^[A-Za-z0-9._@%:+-]{1,255}$ ]]; }
add_remote() { # $1=ssh别名  $2=设备名(可选)
  local alias="$1" name="${2:-$1}"
  if ! valid_name "$name"; then echo "  ✗ 设备名不合法（限字母数字与 . _ -，1–64 字符）：$name"; return 1; fi
  if ! valid_ssh "$alias"; then echo "  ✗ SSH 别名不合法（不能以 - 开头）：$alias"; return 1; fi
  say "探测远端 $alias"
  # -n：ssh 不吃脚本 stdin（否则会吞掉后续 read 的应答，含交互终端输入）
  if ! ssh -n -o BatchMode=yes -o ConnectTimeout=20 "$alias" true 2>/dev/null; then
    echo "  ✗ ssh 不可达（检查免密配置）"; return 1
  fi
  # 远端直接打印数据源标签（zcode/codex/workbuddy），探测路径与 sync/mirror.sh 的 probe_remote 一致；
  # 末尾 true 保证远端恒 exit 0（可达性只由 ssh 本身成败决定），缺 sqlite3/rsync 以 !! 前缀行告警
  local found
  found="$(ssh -n -o BatchMode=yes -o ConnectTimeout=20 "$alias" \
    '[ -e "$HOME/.zcode/cli/db/db.sqlite" ] && echo zcode; [ -e "$HOME/.codex/sessions" ] && echo codex; [ -e "$HOME/.workbuddy/workbuddy.db" ] && echo workbuddy; command -v sqlite3 >/dev/null || echo "!!缺sqlite3"; command -v rsync >/dev/null || echo "!!缺rsync"; true' 2>/dev/null || true)"
  echo "$found" | grep -q "!!" && echo "  警告: $alias 远端缺少 sqlite3/rsync，镜像会失败"
  local tools; tools="$(echo "$found" | grep -v '^!!' | sort -u | tr '\n' ' ')"
  echo "  ✓ 可用数据源: ${tools:-无}"
  [ -z "$tools" ] && { echo "  ✗ 远端无任何数据源，跳过该设备"; return 1; }
  DEV_NAMES+=("$name"); DEV_SSH+=("$alias")
}

if [ -n "$SSH_LIST" ]; then
  IFS=',' read -ra ALIASES <<< "$SSH_LIST"
  for a in "${ALIASES[@]}"; do
    [ -z "$a" ] && continue
    add_remote "${a%%:*}" "${a#*:}" || true
  done
else
  say "添加远端设备（直接回车结束）"
  while :; do
    ask "  远端 SSH 别名（可加 :设备名，如 workstation:desktop）: "
    [ -z "$REPLY" ] && break
    add_remote "${REPLY%%:*}" "${REPLY#*:}" || true
  done
fi

# ---- 端口/刷新 ----
if [ "$ASSUME_YES" -eq 0 ]; then
  ask "服务端口 [8317]: "; [ -n "$REPLY" ] && PORT="$REPLY"
  ask "刷新间隔(分钟) [30]: "; [ -n "$REPLY" ] && REFRESH="$REPLY"
fi
case "$PORT" in ''|*[!0-9]*) echo "端口必须是整数: $PORT"; exit 1 ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "端口需在 1–65535: $PORT"; exit 1; }
case "$REFRESH" in ''|*[!0-9]*) echo "刷新间隔必须是正整数(分钟): $REFRESH"; exit 1 ;; esac
[ "$REFRESH" -ge 1 ] || { echo "刷新间隔需 ≥1 分钟: $REFRESH"; exit 1; }

# ---- 写 agg.config.json ----
# JSON 由 python3 构造并原子落盘：设备名/别名不再手工拼进 JSON 字符串（转义注入面），
# 写临时文件 + rename 保证半写状态不会覆盖旧配置；写完即校验合法性。
say "写入 $CONFIG"
PY_ARGS=("$CONFIG" "$PORT" "$REFRESH" "$LOCAL_NAME")
for i in "${!DEV_SSH[@]}"; do PY_ARGS+=("${DEV_NAMES[$i]}" "${DEV_SSH[$i]}"); done
python3 - "${PY_ARGS[@]}" <<'PY'
import json, os, sys
out, port, refresh, local = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
rest = sys.argv[5:]
pairs = []
# 额外参数是「name ssh name ssh …」的平铺序列（经 argv 传递，不经 shell 拼接）
for i in range(0, len(rest), 2):
    pairs.append({"name": rest[i], "ssh": rest[i + 1]})
cfg = {"server": {"port": port, "refreshMinutes": refresh},
       "devices": [{"name": local, "local": True}] + pairs}
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, out)
json.load(open(out, encoding="utf-8"))  # 自检合法
PY
python3 "$ROOT/scripts/gen-config.py"
echo "  完成。远端设备: ${DEV_SSH[*]:-（无，仅本机）}"

# ---- 可选安装 ----
if [ "$ASSUME_YES" -eq 1 ]; then
  exec bash "$ROOT/scripts/install.sh"
fi
ask "立即执行安装（构建+镜像+launchd，约 10-20 分钟）？[y/N] "
[ "$REPLY" = "y" ] && exec bash "$ROOT/scripts/install.sh"
say "完成配置。稍后可运行: bash scripts/install.sh"
