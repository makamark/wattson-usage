# 多设备镜像体积评估（2026-09-14）

结论：原 SQLite 同步存在确定的整库重复传输，值得优化。此次采用 ZCode 精简 SQLite 导出、旧镜像增量基准、4 KiB 块与传输统计。目录及采集契约不变；未执行真实远端连接。

## 本地测量与根因

源数据 `du -sk`：ZCode 主库 196672 KiB、WAL 16832 KiB，WorkBuddy 256 KiB；Codex sessions 461272 KiB、archived 37556 KiB；镜像合计 1573536 KiB（1.50 GiB）。这是占用空间，区别于下面快照文件的逻辑长度。

将 ZCode 主库及 WAL 复制到 `/tmp/usage-mirror-measure` 后查询：完整性 ok、页大小 4096、47326 页。复制活跃 WAL 库不是生产快照方案，此次只用于离线评估；测量期间快照大小与原文件占用不必相等。

原脚本先删除 `.db.sqlite.tmp*`，再 rsync 到 `.db.sqlite.tmp`，完成后移走该文件。下轮接收端没有基准，因此即使源完全不变也发送整个 VACUUM 输出。不是仅仅“块与页不对齐”。rsync 用滚动校验搜索所有偏移，单次插入不意味着长尾全部失配。

本地系统 rsync 2.6.9（协议 29），通过 `-aI --no-whole-file --stats --block-size=4096` 在 /tmp 模拟远程差分；没有 ssh。以下总量为 rsync 报告的 sent + received，不含 SSH/TCP 开销，也不等同于生产线路抓包：

| 场景（ZCode） | Literal data | sent + received |
|---|---:|---:|
| 原快照、目标无基准 | 188235776 B（179.5 MiB） | 188258909 B |
| 新精简库、首次同步 | 2117632 B（2.02 MiB） | 2118052 B |
| 新精简库、完全无变化 | 0 B | 5331 B |
| 新精简库、仅一条 output_tokens +1 | 4096 B | 9429 B |

按每天 48 轮、同等规模源计算，原 ZCode 约 8.41 GiB/日/台（不含 Codex）。新方案首轮约 2 MiB；小变化在 KiB 级，密集变化可能重传大部分精简库。不能从一次副本推断生产每 30 分钟的 usage 增长率；也不能推断另一台机器的库同样大。WorkBuddy 原来每轮约 256 KiB，现在也有差分基准。

Codex 首次同步仍约 487 MiB，后续是新增文件及旧文件修改块，加文件清单/校验开销；没有前后两轮样本，无法诚实给出每轮具体字节。目录镜像不会每轮新增一份历史，但会随源历史增长。所有 rsync 现输出 `--stats` 到 stderr，可从实际运行日志区分 Literal data、Matched data 和 sent/received；不要把 Total transferred file size 当作线上增量字节。

## 方案与数据兼容性

原生解析器（`Sources/WattsonCore/Parsing/SessionScanner.swift`）实际读取：

- session：id、directory。
- model_usage：id、session_id、turn_id、model_id、五种 token 字段、started_at、completed_at。
- tool_usage：session_id、turn_id、tool_name、started_at。

turn_usage 并未被此 provider 查询。通过 ATTACH + 单一事务导出以上全部历史行，保留查询字段，并建立两个 session_id 索引。沿用原生解析器做 token 拆分、去重与价格计算；没有增加远端 JSON 解析或额外依赖。当前副本 214/4044/5643 行的保留字段已与原库逐行一致核对。导出库 2.02 MiB，比 VACUUM 库缩小 98.9%。原库 part 表占 139100160 B，正文是明显冗余来源。

WorkBuddy 仅 256 KiB，保留原 VACUUM。新库仍位于 mirror/<设备>/zcode/db.sqlite 和 workbuddy/db.sqlite，设备配置与采集管线无需修改。新导出失败或字段不兼容时非零退出并保留旧镜像，不静默退回大库或发布半成品。

本地先复制正式库到临时目标作为 rsync 基准，成功后 mv 原子替换；不使用硬链接或 --inplace。`-I` 防止同秒同大小快照被跳过。4 KiB 对齐本次测得的页，不能保证重排后所有逻辑未改数据都匹配；其它页大小仍保证正确性。首次由大镜像迁移时可能有一次较大的本地复制，之后基准仅约 2 MiB。

## 未采用的方向与剩余边界

- 只改块大小：不解决临时目标没有基准，也不减少原始正文占用。
- 跨轮稳定快照及变化指纹：主库 mtime 不能涵盖 WAL；大小/秒级 mtime 有漏变风险，跨连接 PRAGMA data_version 不能当持久版本。精简导出每轮只写约 2 MiB，暂不增加持久缓存与远端锁复杂度。仍会每轮查询源 usage 表及重建小库，远端 I/O 并非归零。
- 整库 `.backup`：保留页布局但仍复制约 185 MiB，无法删除不消费的正文，收益不如 SQL 投影。
- Codex 最小文本过滤：provider 需要 session_meta、turn_context、累计 usage、模型归属及分叉历史去重；shell 文本过滤不能可靠替代其解析。完整结构化 usage 交换协议可以进一步节省空间，但需要版本、去重和历史迁移契约，此次不引入。
- 保留期限/压缩：截断会损失看板历史，压缩格式不能由当前 provider 直接读取；本地单独删文件还会在下一轮被 rsync 拉回。因此未削减 Codex 历史，本地 1.5 GiB 镜像的大头仍在，不能宣称已解决历史无界增长。

## 验证与来源

`bash sync/mirror.test.sh`：覆盖原有汇总、锁、多设备、stdin 行为，并新增真实 SQLite 投影、schema 失败、基准参数、失败原子性、真实 rsync 差分重建及零变化轮。`cd server && npm test`：70 通过，1 跳过。

- [rsync 滚动匹配算法](https://rsync.samba.org/tech_report/node4.html)
- [rsync 2.6.9 原版选项文档](https://raw.githubusercontent.com/RsyncProject/rsync/v2.6.9/rsync.yo)：-I、--block-size、--stats、--timeout 均支持；本机旧版实际执行验证。
- [SQLite backup 说明](https://www.sqlite.org/backup.html)

测量仅在 /tmp 副本上执行。未写 HOME 源库、现有镜像，未提交 git；工作区其它既有改动保持原样。
