#!/bin/bash
# sync/mirror.sh — 按 agg.config.json 循环拉取所有远端设备的数据子集（一致性快照）。
# 语义：sqlite 走远端精简导出/快照 + 本地原子替换；单设备失败/不可达不中断其它设备。
# 结束输出机器可读汇总行「ROUND RESULT devices=N ok=X failed=Y skipped=Z busy=W」；
# 有 failed 或 skipped（含 ssh 不可达、无数据源、设备条目非法）时以非零退出，
# 调用方（launchd 忽略退出码；菜单栏客户端/App 向导据此判断本轮是否完整成功）。
set -u
# launchd 环境下 PATH 极简，显式收紧到系统路径（ssh/rsync/sqlite3 均为系统自带）。
# MIRROR_PATH_PREFIX 仅测试用：允许把桩 ssh/rsync 排在系统工具前，生产环境勿设。
PATH="${MIRROR_PATH_PREFIX:-}/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# AGG_CONFIG 重定向配置文件（菜单栏客户端打包态用），默认仓库根 agg.config.json
CONFIG="${AGG_CONFIG:-$ROOT/agg.config.json}"
# MIRROR_BASE 可重定向镜像根（测试隔离用），默认 ~/codeburn-agg/mirror
MIRROR_BASE="${MIRROR_BASE:-$HOME/codeburn-agg/mirror}"
LOG_TAG="[mirror]"

# 日志走 stderr：设备循环用 stdout 传每台设备的终态词（ok/failed/skipped/busy），
# 命令替换捕获终态时不会把日志吞进变量；客户端两条流都会采集，展示不受影响。
log() { echo "$LOG_TAG $(date '+%F %T') $*" >&2; }

# 设备列表：每行 "name<TAB>ssh"。优先 MIRROR_DEVICES（菜单栏客户端注入，避免调
# python3——全新 Mac 上 /usr/bin/python3 会触发「安装命令行开发者工具」弹窗）；
# 注入即为唯一事实来源：设为空串 = 无远端设备（不回退读配置，也不调 python3）。
# 未注入时才回退解析配置文件（launchd 旧路径）。
list_devices() {
  if [ "${MIRROR_DEVICES+set}" = set ]; then
    [ -n "$MIRROR_DEVICES" ] && printf '%s\n' "$MIRROR_DEVICES"
    return 0
  fi
  python3 - "$CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for d in cfg.get("devices", []):
    if not d.get("local") and d.get("ssh"):
        print(f"{d['name']}\t{d['ssh']}")
PY
}

# 设备条目校验（与 app/src/config.ts 的校验同口径）：设备名会用作本地镜像目录名、
# 远端 /tmp 临时文件后缀并进入看板「设备」维度；SSH 目标是远端命令行参数。
# 二者都必须是受限字符集，防止 shell 元字符/选项注入。
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$ ]]; }
valid_ssh() {
  case "$1" in -*) return 1 ;; esac  # 以 - 开头会被 ssh 当作选项
  [[ "$1" =~ ^[A-Za-z0-9._@%:+-]{1,255}$ ]]
}

# 锁管理：锁目录内写 pid；残留锁（崩溃/kill -9 后 pid 已死）自动接管。
CURRENT_LOCK=""
cleanup_lock() {
  if [ -n "$CURRENT_LOCK" ]; then
    rm -f "$CURRENT_LOCK/pid" 2>/dev/null
    rmdir "$CURRENT_LOCK" 2>/dev/null
    CURRENT_LOCK=""
  fi
}
trap cleanup_lock EXIT
trap 'cleanup_lock; exit 130' INT
trap 'cleanup_lock; exit 143' TERM

acquire_lock() { # $1=锁目录；0=拿到，1=有活进程在跑
  local lock="$1"
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" > "$lock/pid"
    CURRENT_LOCK="$lock"
    return 0
  fi
  local pid=""
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  # pid 文件缺失或进程已死 → 上一轮崩溃/强杀残留，接管（rm -rf 防目录内有异物）
  log "检测到残留锁（pid=${pid:-未知}），接管重试"
  rm -rf "$lock"
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" > "$lock/pid"
    CURRENT_LOCK="$lock"
    return 0
  fi
  return 1
}

# 远端探测：输出存在的数据源路径（每行一个）。
# -n：ssh 不吃脚本 stdin（否则会吞掉设备循环里后续设备的行——setup.sh 同款修复）。
# 末尾 `; true`：远端循环以最后一条 [ -e ] 的状态退出，路径部分缺失（如无 archived_sessions）
# 时若无 true 兜底会 exit 1 → ssh 1 → 被误判为整台不可达。加上后「可达但部分缺失」恒 exit 0，
# 可达性仅由 ssh 本身成败决定；「无任何数据源」仍由调用方 [ -z "$sources" ] 判断。
probe_remote() {
  ssh -n -o BatchMode=yes -o ConnectTimeout=20 "$1" 'for p in "$HOME/.zcode/cli/db/db.sqlite" "$HOME/.workbuddy/workbuddy.db" "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions"; do [ -e "$p" ] && echo "$p"; done; true' 2>/dev/null
}

mirror_device() { # $1=name $2=ssh；0=完成，1=有失败项
  local name="$1" ssh_alias="$2" failed=0
  local mirror="$MIRROR_BASE/$name"
  mkdir -p "$mirror/zcode" "$mirror/workbuddy" "$mirror/codex"
  local lock="$mirror/.lock"
  if ! acquire_lock "$lock"; then
    log "$name: 上一轮仍在进行（锁被活进程持有），本轮跳过"
    echo "busy"; return 3
  fi
  # 先摘 RETURN trap 再清理：cleanup_lock 自身的 return 不得再触发本 trap
  trap 'trap - RETURN; cleanup_lock' RETURN
  rm -f "$mirror"/zcode/.db.sqlite.tmp* "$mirror"/workbuddy/.db.sqlite.tmp* 2>/dev/null || true

  local sources
  if ! sources="$(probe_remote "$ssh_alias")"; then
    log "$name: ssh 不可达（${ssh_alias}），本轮跳过"
    echo "skipped"; return 2
  fi
  if [ -z "$sources" ]; then log "$name: 远端未发现任何数据源，跳过"; echo "skipped"; return 2; fi

  # sqlite 快照（远端产 /tmp 快照 → 拉回 → 原子替换）
  local remote_tmp_suffix="${name}-mirror"
  local vacuum_cmds=()
  echo "$sources" | grep -q "zcode/cli/db/db.sqlite" && vacuum_cmds+=("zcode")
  echo "$sources" | grep -q "workbuddy/workbuddy.db" && vacuum_cmds+=("workbuddy")
  if [ ${#vacuum_cmds[@]} -gt 0 ]; then
    # 这里不能加 -n：-n 会把 stdin 重定向到 /dev/null，heredoc 脚本到不了远端，
    # bash -s 读到空输入静默 exit 0，快照永远拉不回来（设备循环本身走 fd 3，不受影响）
    if ssh -o BatchMode=yes -o ConnectTimeout=20 "$ssh_alias" /bin/bash -s <<REMOTE
for db in ${vacuum_cmds[*]}; do
  case \$db in
    zcode) src="\$HOME/.zcode/cli/db/db.sqlite" ;;
    workbuddy) src="\$HOME/.workbuddy/workbuddy.db" ;;
  esac
  rm -f "/tmp/\${db}-${remote_tmp_suffix}.sqlite"
  # ZCode 仅保留当前 provider 查询的字段；单事务保证三张表来自同一读快照。
  # 不复制正文，也不重算 token/cost；字段变化时失败并保留本地旧镜像。
  if [ "\$db" = zcode ]; then
    sqlite3 "\$src" "
      ATTACH DATABASE '/tmp/\${db}-${remote_tmp_suffix}.sqlite' AS usage_mirror;
      BEGIN;
      CREATE TABLE usage_mirror.session AS SELECT id, directory FROM main.session;
      CREATE TABLE usage_mirror.model_usage AS
        SELECT id, session_id, turn_id, model_id, input_tokens, output_tokens,
               reasoning_tokens, cache_creation_input_tokens, cache_read_input_tokens,
               started_at, completed_at FROM main.model_usage ORDER BY rowid;
      CREATE TABLE usage_mirror.tool_usage AS
        SELECT session_id, turn_id, tool_name, started_at FROM main.tool_usage ORDER BY rowid;
      CREATE INDEX usage_mirror.model_usage_session ON model_usage(session_id);
      CREATE INDEX usage_mirror.tool_usage_session ON tool_usage(session_id);
      COMMIT;
    " || { rm -f "/tmp/\${db}-${remote_tmp_suffix}.sqlite"; exit 1; }
  else
    sqlite3 "\$src" "VACUUM INTO '/tmp/\${db}-${remote_tmp_suffix}.sqlite'" || { rm -f "/tmp/\${db}-${remote_tmp_suffix}.sqlite"; exit 1; }
  fi
done
REMOTE
    then
      local db
      for db in "${vacuum_cmds[@]}"; do
        # 临时目标原本每轮不存在，rsync 无基准会全量传输。复制旧库作基准，
        # 不用硬链接/--inplace，避免失败时污染服务端正在读取的正式库。
        if [ -f "$mirror/$db/db.sqlite" ] && ! cp -p "$mirror/$db/db.sqlite" "$mirror/$db/.db.sqlite.tmp"; then
          log "$name: $db 增量基准准备失败"
          failed=1
          continue
        fi
        # -I 防止同秒、同大小快照被误跳过；4 KiB 对齐常见 SQLite 页，
        # 但不承诺 VACUUM/导出重排后所有未变更逻辑行都能匹配。
        # --stats 必须走 stderr，避免混入设备终态；这些选项均支持 rsync 2.6.9。
        if rsync -a -I --block-size=4096 --stats --timeout=300 "$ssh_alias:/tmp/$db-${remote_tmp_suffix}.sqlite" "$mirror/$db/.db.sqlite.tmp" </dev/null >&2 \
          && mv "$mirror/$db/.db.sqlite.tmp" "$mirror/$db/db.sqlite"; then
          log "$name: $db 快照完成"
        else
          rm -f "$mirror/$db/.db.sqlite.tmp"
          log "$name: $db 快照拉取失败"
          failed=1
        fi
      done
    else
      log "$name: 远端导出/快照失败（sqlite3 缺失或库损坏），跳过 sqlite 源"
      failed=1
    fi
    # -n：清理命令不读 stdin，不吃设备循环的输入
    ssh -n -o BatchMode=yes -o ConnectTimeout=20 "$ssh_alias" "rm -f /tmp/zcode-${remote_tmp_suffix}.sqlite /tmp/workbuddy-${remote_tmp_suffix}.sqlite" \
      </dev/null 2>/dev/null || log "$name: 远端临时快照清理失败（下一轮自愈）"
  fi

  # codex 纯 jsonl 直接增量：源不存在→跳过（非失败）；存在但 rsync 失败→记失败项
  if echo "$sources" | grep -q ".codex/sessions"; then
    rsync -a --delete --stats --timeout=300 "$ssh_alias:.codex/sessions/" "$mirror/codex/sessions/" </dev/null >&2 \
      && log "$name: codex sessions 同步完成" || { log "$name: codex sessions 同步失败"; failed=1; }
  else
    log "$name: codex sessions 不存在，跳过"
  fi
  if echo "$sources" | grep -q ".codex/archived_sessions"; then
    rsync -a --delete --stats --timeout=300 "$ssh_alias:.codex/archived_sessions/" "$mirror/codex/archived_sessions/" </dev/null >&2 \
      && log "$name: codex archived 同步完成" || { log "$name: codex archived 同步失败"; failed=1; }
  else
    log "$name: codex archived 不存在，跳过"
  fi

  if [ "$failed" -eq 0 ]; then log "$name: 完成"; echo "ok"; return 0; fi
  log "$name: 本轮有失败项"
  echo "failed"; return 1
}

DEVICE_COUNT=0 ROUND_OK=0 ROUND_FAILED=0 ROUND_SKIPPED=0 ROUND_BUSY=0
# 设备列表走独立文件描述符 3：循环体内任何未重定向 stdin 的命令（ssh/rsync）
# 都不会再吞掉后续设备行
while IFS=$'\t' read -r name ssh_alias <&3; do
  [ -z "$name" ] && continue
  DEVICE_COUNT=$((DEVICE_COUNT + 1))
  if ! valid_name "$name" || ! valid_ssh "$ssh_alias"; then
    log "设备条目不合法（名称限字母数字与 . _ - 且不以 - 开头，≤64 字符；SSH 目标限 [A-Za-z0-9._@%:+-] 且不以 - 开头）：${name} → 记为失败"
    ROUND_FAILED=$((ROUND_FAILED + 1))
    continue
  fi
  outcome="$(mirror_device "$name" "$ssh_alias")"
  case "$outcome" in
    ok) ROUND_OK=$((ROUND_OK + 1)) ;;
    failed) ROUND_FAILED=$((ROUND_FAILED + 1)) ;;
    skipped) ROUND_SKIPPED=$((ROUND_SKIPPED + 1)) ;;
    busy) ROUND_BUSY=$((ROUND_BUSY + 1)) ;;
    *) ROUND_FAILED=$((ROUND_FAILED + 1)) ;;
  esac
done 3< <(list_devices)
cleanup_lock

log "ROUND RESULT devices=$DEVICE_COUNT ok=$ROUND_OK failed=$ROUND_FAILED skipped=$ROUND_SKIPPED busy=$ROUND_BUSY"
if [ "$DEVICE_COUNT" -eq 0 ]; then
  log "配置中无远端设备（agg.config.json）"
  exit 0
fi
if [ "$ROUND_FAILED" -gt 0 ] || [ "$ROUND_SKIPPED" -gt 0 ]; then
  log "本轮未完整成功（${DEVICE_COUNT} 台设备：完成 ${ROUND_OK}，失败 ${ROUND_FAILED}，跳过 ${ROUND_SKIPPED}，占用 ${ROUND_BUSY}）"
  exit 1
fi
log "全部完成（${DEVICE_COUNT} 台设备）"
exit 0
