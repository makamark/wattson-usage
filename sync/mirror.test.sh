#!/bin/bash
# sync/mirror.test.sh — sync/mirror.sh 的桩集成测试（不连真实远端）。
# 覆盖评审修复的回归场景：
#   1) 设备循环不被 ssh/rsync 吞掉后续行（P1：ssh 未加 -n 时多设备只同步第一台）
#   2) ROUND RESULT 汇总行 + 退出码语义（ok→0；failed/skipped→非零）
#   3) 残留锁自愈（pid 已死→接管）与活锁占用（→busy，不整轮失败）
#   4) MIRROR_DEVICES 设为空串 = 无设备（不再回退调 python3）
#   5) 非法设备条目记为失败
#   6) VACUUM 脚本必须经 stdin 送达远端（ssh -n 会吞掉 heredoc → 快照静默失败）
# 运行：bash sync/mirror.test.sh（全部通过静默退出 0，失败打印 ✗）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MIRROR="$HERE/mirror.sh"
TMP="$(mktemp -d /tmp/mirror-test.XXXXXX)"
STUB="$TMP/bin"; mkdir -p "$STUB"
FAILURES=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---- 桩 ssh/rsync ----
cat > "$STUB/ssh" <<'SSH'
#!/bin/bash
# 桩 ssh：先取第一个非选项参数为「目标」，unreachable.test → exit 255（不可达）；
# probe 调用（脚本参数含 "for p in"）→ 打印 zcode+codex 两个数据源；
# VACUUM 调用（脚本参数含 "/bin/bash"）→ stdin 落盘到 $MIRROR_TEST_VAC_STDIN
#（文件为空 = 脚本没送达，即 ssh -n 吞 heredoc 回归）；其余调用（清理）→ exit 0。
# 始终消费自己的 stdin，绝不继承调用方的设备列表。
if [[ "$*" == *"/bin/bash"* ]]; then
  cat > "${MIRROR_TEST_VAC_STDIN:-/dev/null}"
else
  cat >/dev/null 2>&1
fi
dest=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then prev=""; continue; fi  # -o 的值（BatchMode=yes 等）不是目标
  case "$a" in
    -*) [ "$a" = "-o" ] && prev="-o"
        continue ;;
  esac
  if [ -z "$dest" ]; then dest="$a"; fi
  break
done
[ "$dest" = "unreachable.test" ] && exit 255
for a in "$@"; do
  if [[ "$a" == *"for p in"* ]]; then
    echo "$HOME/.zcode/cli/db/db.sqlite"
    echo "$HOME/.codex/sessions"
    exit 0
  fi
done
exit 0
SSH
cat > "$STUB/rsync" <<'RSYNC'
#!/bin/bash
# 桩 rsync：本地目标为目录（结尾 /）时建目录；为文件时落一个非空文件，
# 让「拉回 + mv 原子替换」路径走通
dest="${@: -1}"
case "$dest" in
  *":") ;;  # 远端目标，跳过
  */) mkdir -p "$dest" ;;
  *) mkdir -p "$(dirname "$dest")" && echo stub > "$dest" ;;
esac
exit 0
RSYNC
chmod +x "$STUB/ssh" "$STUB/rsync"

expect_contains() { # $1=描述 $2=haystack $3=needle
  if [[ "$2" == *"$3"* ]]; then echo "  ✓ $1"; else echo "  ✗ $1（未找到：$3）"; echo "--- 输出 ---"; echo "$2"; FAILURES=$((FAILURES+1)); fi
}
expect_not_contains() {
  if [[ "$2" != *"$3"* ]]; then echo "  ✓ $1"; else echo "  ✗ $1（不应出现：$3）"; FAILURES=$((FAILURES+1)); fi
}
expect_code() { # $1=描述 $2=期望退出码 $3=实际退出码
  if [ "$2" -eq "$3" ]; then echo "  ✓ $1（exit $3）"; else echo "  ✗ $1（期望 exit $2，实际 $3）"; echo "--- 输出 ---"; echo "$OUT"; FAILURES=$((FAILURES+1)); fi
}

run_mirror() { # $1=设备注入串 → 设置全局 OUT/CODE
  local devices="$1"
  OUT="$(MIRROR_PATH_PREFIX="$STUB:" MIRROR_BASE="$TMP/mirror" AGG_CONFIG="$TMP/agg.config.json" \
    MIRROR_DEVICES="$devices" bash "$MIRROR" 2>&1)"
  CODE=$?
}

# ---- 用例 1：三台设备全部处理（吞设备行回归）+ 全部完成 exit 0 ----
echo "用例 1：三台设备全部同步（ssh -n / FD3 回归）"
run_mirror "$(printf 'd1\tok.test\nd2\tok.test\nd3\tok.test')"
expect_code "全部完成退出码" 0 "$CODE"
expect_contains "ROUND RESULT 3 台全 ok" "$OUT" "ROUND RESULT devices=3 ok=3 failed=0 skipped=0 busy=0"
for d in d1 d2 d3; do
  if [ -f "$TMP/mirror/$d/zcode/db.sqlite" ]; then echo "  ✓ $d 快照已拉回"; else echo "  ✗ $d 快照缺失（设备行被吞？）"; FAILURES=$((FAILURES+1)); fi
done

# ---- 用例 2：中间一台不可达 → skipped + 非零退出，后续设备仍被处理 ----
echo "用例 2：中间设备不可达（skipped 计数 + 后续设备不受影响）"
run_mirror "$(printf 'd1\tok.test\nd2\tunreachable.test\nd3\tok.test')"
expect_code "有 skipped 时非零退出" 1 "$CODE"
expect_contains "ROUND RESULT skipped=1" "$OUT" "ROUND RESULT devices=3 ok=2 failed=0 skipped=1 busy=0"
if [ -f "$TMP/mirror/d3/zcode/db.sqlite" ]; then echo "  ✓ 不可达设备之后的 d3 仍被处理"; else echo "  ✗ d3 未被处理"; FAILURES=$((FAILURES+1)); fi

# ---- 用例 3：单台有失败项（rsync 失败）→ failed + 非零退出 ----
echo "用例 3：快照拉取失败（failed 计数）"
cat > "$STUB/rsync" <<'RSYNC'
#!/bin/bash
exit 1
RSYNC
chmod +x "$STUB/rsync"
run_mirror "$(printf 'd1\tok.test')"
expect_code "有 failed 时非零退出" 1 "$CODE"
expect_contains "ROUND RESULT failed=1" "$OUT" "ROUND RESULT devices=1 ok=0 failed=1 skipped=0 busy=0"
cat > "$STUB/rsync" <<'RSYNC'
#!/bin/bash
dest="${@: -1}"
if [[ "$dest" != *":"* ]]; then mkdir -p "$(dirname "$dest")" && echo stub > "$dest"; fi
exit 0
RSYNC
chmod +x "$STUB/rsync"

# ---- 用例 4：残留锁（pid 已死）自动接管 ----
echo "用例 4：残留锁自愈"
mkdir -p "$TMP/mirror/d1/.lock"
echo 999999999 > "$TMP/mirror/d1/.lock/pid"  # 不存在的 pid
run_mirror "$(printf 'd1\tok.test')"
expect_code "残留锁被接管后本轮成功" 0 "$CODE"
expect_contains "接管日志" "$OUT" "残留锁"
if [ ! -d "$TMP/mirror/d1/.lock" ]; then echo "  ✓ 锁已清理"; else echo "  ✗ 锁未清理"; FAILURES=$((FAILURES+1)); fi

# ---- 用例 5：活进程持锁 → busy，不算失败（exit 0） ----
echo "用例 5：锁被活进程持有 → busy"
mkdir -p "$TMP/mirror/d1/.lock"
echo $$ > "$TMP/mirror/d1/.lock/pid"  # 当前测试进程还活着
run_mirror "$(printf 'd1\tok.test')"
expect_code "busy 不使整轮失败" 0 "$CODE"
expect_contains "ROUND RESULT busy=1" "$OUT" "ROUND RESULT devices=1 ok=0 failed=0 skipped=0 busy=1"
rm -rf "$TMP/mirror/d1/.lock"

# ---- 用例 6：MIRROR_DEVICES 空串 = 无设备（不回退 python） ----
echo "用例 6：空注入 = 无设备"
run_mirror ""
expect_code "无设备退出 0" 0 "$CODE"
expect_contains "devices=0" "$OUT" "ROUND RESULT devices=0 ok=0 failed=0 skipped=0 busy=0"
expect_not_contains "未触发 python 回退" "$OUT" "Traceback"

# ---- 用例 7：非法设备条目 → 记失败 ----
echo "用例 7：非法设备条目"
run_mirror "$(printf 'bad name\tok.test\n-x\trsh.test')"
expect_code "非法条目使整轮失败" 1 "$CODE"
expect_contains "ROUND RESULT failed=2" "$OUT" "ROUND RESULT devices=2 ok=0 failed=2 skipped=0 busy=0"

# ---- 用例 8：VACUUM 脚本经 stdin 送达远端（ssh -n 吞 heredoc 回归） ----
# 回归背景：远端快照步曾误加 -n，heredoc 被重定向到 /dev/null，远端 bash -s
# 读到空输入静默 exit 0，快照永远拉不回（本地日志仅见「快照拉取失败」）。
echo "用例 8：VACUUM 脚本送达远端"
VAC_STDIN="$TMP/vac-stdin.txt"; rm -f "$VAC_STDIN"
OUT="$(MIRROR_PATH_PREFIX="$STUB:" MIRROR_BASE="$TMP/mirror" AGG_CONFIG="$TMP/agg.config.json" \
  MIRROR_DEVICES="$(printf 'd1\tok.test')" MIRROR_TEST_VAC_STDIN="$VAC_STDIN" \
  bash "$MIRROR" 2>&1)"; CODE=$?
if [ -s "$VAC_STDIN" ]; then
  echo "  ✓ heredoc 脚本已送达远端 stdin"
  # ${db} 在远端循环里才展开，heredoc 原文保留变量形式
  expect_contains "脚本含 VACUUM INTO 目标模板" "$(cat "$VAC_STDIN")" 'VACUUM INTO '"'"'/tmp/${db}-d1-mirror.sqlite'"'"''
  expect_contains "脚本含远端源路径分支" "$(cat "$VAC_STDIN")" 'zcode) src="$HOME/.zcode/cli/db/db.sqlite"'
else
  echo "  ✗ heredoc 脚本未送达远端（stdin 为空，-n 回归？）"; FAILURES=$((FAILURES+1))
fi


# ---- 用例 9：实际执行送达远端的 SQL（所有输入输出隔离在 /tmp） ----
echo "用例 9：精简导出保留查询字段、历史 usage，去掉正文"
FIXTURE="$TMP/remote"
mkdir -p "$FIXTURE/.zcode/cli/db"
sqlite3 "$FIXTURE/.zcode/cli/db/db.sqlite" <<'SQL'
CREATE TABLE session(id TEXT, directory TEXT, body TEXT);
CREATE TABLE model_usage(id TEXT, session_id TEXT, turn_id TEXT, model_id TEXT,
 input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
 cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER,
 started_at INTEGER, completed_at INTEGER, body TEXT);
CREATE TABLE tool_usage(session_id TEXT, turn_id TEXT, tool_name TEXT, started_at INTEGER, body TEXT);
INSERT INTO session VALUES('s', '/项目/a', '正文');
INSERT INTO model_usage VALUES('u', 's', 't', 'm', 10, 20, 3, 4, 5, 1000, NULL, '正文');
INSERT INTO tool_usage VALUES('s', 't', 'shell', 999, '正文');
SQL
# 仅替换临时目标目录；执行的 SQL 就是生产脚本发给 ssh 的内容。
sed "s|/tmp/|$TMP/|g" "$VAC_STDIN" > "$TMP/remote.sh"
HOME="$FIXTURE" bash "$TMP/remote.sh"
expect_code "远端 SQL 执行成功" 0 "$?"
PROJECTED="$TMP/zcode-d1-mirror.sqlite"
RESULT="$(sqlite3 "$PROJECTED" "SELECT s.directory,m.id,m.input_tokens,m.output_tokens,m.reasoning_tokens,m.cache_creation_input_tokens,m.cache_read_input_tokens,m.started_at,coalesce(m.completed_at,'NULL'),t.tool_name FROM session s JOIN model_usage m ON m.session_id=s.id JOIN tool_usage t ON t.turn_id=m.turn_id;")"
expect_contains "查询值原样保留" "$RESULT" '/项目/a|u|10|20|3|4|5|1000|NULL|shell'
expect_not_contains "精简 schema 不含正文列" "$(sqlite3 "$PROJECTED" .schema)" 'body'
expect_contains "数据库完整" "$(sqlite3 "$PROJECTED" 'PRAGMA integrity_check;')" 'ok'
sqlite3 "$FIXTURE/.zcode/cli/db/db.sqlite" 'DROP TABLE model_usage;'
HOME="$FIXTURE" bash "$TMP/remote.sh" >/dev/null 2>&1
expect_code "schema 不兼容时远端非零退出" 1 "$?"
if [ -e "$PROJECTED" ]; then echo "  ✗ 失败后留下半成品"; FAILURES=$((FAILURES+1)); fi

# ---- 用例 10：第二轮提供旧库基准；失败保留旧库且不中断后续设备 ----
echo "用例 10：增量基准、统计输出与失败原子性"
cat > "$STUB/rsync" <<'RSYNC'
#!/bin/bash
dest="${@: -1}"
case "$dest" in
  */.db.sqlite.tmp)
    [ -s "$dest" ] || exit 2
    [[ "$*" == *"--block-size=4096"* && "$*" == *"--stats"* && "$*" == *"-I"* ]] || exit 3
    echo 'Literal data: 4096 bytes'
    case "$dest" in
      */d1/*) echo broken > "$dest"; exit 1 ;;
      *) echo updated > "$dest" ;;
    esac ;;
esac
exit 0
RSYNC
echo original > "$TMP/mirror/d1/zcode/db.sqlite"
run_mirror "$(printf 'd1\tok.test\nd3\tok.test')"
expect_code "单设备传输失败非零退出" 1 "$CODE"
expect_contains "统计不污染终态且后续设备成功" "$OUT" 'ROUND RESULT devices=2 ok=1 failed=1 skipped=0 busy=0'
expect_contains "失败保留正式库" "$(cat "$TMP/mirror/d1/zcode/db.sqlite")" original
expect_contains "成功原子替换正式库" "$(cat "$TMP/mirror/d3/zcode/db.sqlite")" updated
if [ -e "$TMP/mirror/d1/zcode/.db.sqlite.tmp" ]; then echo "  ✗ 失败临时文件未清理"; FAILURES=$((FAILURES+1)); fi

# ---- 用例 11：系统 rsync 的真实增量传输（本地强制启用差分，不用 ssh） ----
echo "用例 11：真实 rsync 页级增量与结果一致性"
sqlite3 "$TMP/delta-source.sqlite" 'CREATE TABLE usage(id INTEGER PRIMARY KEY, payload BLOB, tokens INTEGER); INSERT INTO usage VALUES(1,randomblob(131072),10);'
cp -p "$TMP/delta-source.sqlite" "$TMP/delta-target.sqlite"
sqlite3 "$TMP/delta-source.sqlite" 'UPDATE usage SET tokens=11 WHERE id=1;'
STATS="$(/usr/bin/rsync -a -I --no-whole-file --block-size=4096 --stats "$TMP/delta-source.sqlite" "$TMP/delta-target.sqlite")"
expect_code "真实 rsync 成功" 0 "$?"
cmp -s "$TMP/delta-source.sqlite" "$TMP/delta-target.sqlite"
expect_code "差分重建逐字节一致" 0 "$?"
expect_not_contains "复用旧页而非整库传输" "$STATS" 'Matched data: 0 bytes'
STATS="$(/usr/bin/rsync -a -I --no-whole-file --block-size=4096 --stats "$TMP/delta-source.sqlite" "$TMP/delta-target.sqlite")"
expect_code "无变化轮成功" 0 "$?"
expect_contains "无变化轮没有 literal 数据" "$STATS" 'Literal data: 0 bytes'

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "全部用例通过 ✓"
  exit 0
fi
echo "$FAILURES 个断言失败 ✗"
exit 1
