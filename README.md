<div align="center">

<img src="docs/logo.png" width="168" alt="Wattson logo"/>

# ⚡ Wattson

**多机 AI 编码用量侦探**

*The multi-machine AI coding usage detective*

一个常驻菜单栏的小侦探：盯住你**每一台机器**上的 AI 编码工具，把 Token、调用与成本汇成一块本地看板——数据不出你的 Mac。

[![license](https://img.shields.io/badge/license-MIT-22c55e?style=flat-square)](LICENSE)
[![platform](https://img.shields.io/badge/platform-macOS_11+-111318?style=flat-square&logo=macos)](#-支持平台全景)
[![用量解析](https://img.shields.io/badge/用量解析-42_工具-F97318?style=flat-square)](#-支持平台全景)
[![远端同步](https://img.shields.io/badge/远端同步-零安装-8B5CF6?style=flat-square)](#-支持平台全景)
[![powered by](https://img.shields.io/badge/powered_by-codeburn-F97318?style=flat-square)](https://github.com/getagentseal/codeburn)
[![node](https://img.shields.io/badge/node-%3E%3D22.13-339933?style=flat-square&logo=nodedotjs)](#-快速开始)

| 菜单栏小窗 | 完整看板 |
|:---:|:---:|
| ![popup](docs/acceptance-app-popup.png) | ![dashboard](docs/acceptance-dashboard.png) |

</div>

---

## ✨ 特性

- 🔭 **一处看全部** —— 本机 42 种 AI 编码工具自动发现，多台远端机器经 SSH 镜像汇总；按 天/小时 × 设备/工具/模型/项目 任意切片，看 Token、调用量与估算成本
- 🕵️ **菜单栏侦探** —— 托盘标题常显近 24h Token；左键弹状态小窗（KPI + 分工具/设备条形图），右键开完整看板；首运行 GUI 向导五分钟配好多机
- 🧾 **订阅额度卡片** —— GLM / Codex / Claude / Cursor / WorkBuddy / Trae / Kimi / Gemini / Grok / Zed / Kiro / Codebuff / Factory / Copilot / OpenRouter / MiniMax 共 16 个账号的额度窗口、已用百分比与重置倒计时，直连各家官方接口只读拉取
- 🛰️ **远端零安装** —— 远端机器只需要系统自带的 `ssh` + `rsync` + `sqlite3`，不装 Node、不装 Python、不留常驻进程；zcode 库在远端投影成 ~2MB 精简快照，增量轮传输 KiB 级（[实测](docs/mirror-volume.md)）
- 🔒 **数据不出本机** —— 服务只绑 `127.0.0.1`，无遥测、无云端；订阅凭据只在服务端内存解密，不落看板
- 💰 **可解释的成本** —— LiteLLM 官方价目折算；reasoning-in-output 工具按 billable 口径去重计价；内部模型名可用 `model-alias` 一键映射

## 🌍 English Overview

**Wattson** is a local-first, open-source **AI coding usage tracker and subscription-quota dashboard** for macOS. It auto-discovers **42 AI coding tools** on your machine — Claude Code, Codex, Cursor, Gemini, ZCode (GLM Coding Plan), Kimi, Qwen, Copilot and more — and merges their local data into one private dashboard: tokens, calls and estimated cost, sliceable by **device / tool / model / project** over day or hour buckets.

What no other usage monitor gives you in one package:

- **Multi-machine aggregation with zero remote install** — your other Macs / Linux boxes need nothing but system `ssh` + `rsync` + `sqlite3`. Wattson SSH-pulls a minimal projection of each remote database (~2 MB out of a ~190 MB SQLite library, KiB-level incremental rounds) every 30 minutes. No agent, no daemon, no listening port on the remote side.
- **Three surfaces, one app** — a menu-bar popup with live 24 h tokens, a full ECharts web dashboard, and a REST API bound to `127.0.0.1`.
- **Subscription quota cards** — GLM Coding Plan (ZCode), Codex (ChatGPT), Claude Code, Cursor, WorkBuddy, Trae, Kimi, Gemini, Grok, Zed, Kiro, Codebuff, Factory, Copilot, OpenRouter and MiniMax: 16 accounts with quota windows, remaining % and reset countdowns, pulled read-only from official endpoints.
- **Private by construction** — localhost-only, no telemetry, no cloud; credentials are decrypted in server memory and never reach the UI.

Looking for a self-hosted Claude Code usage dashboard, a Codex / GLM Coding Plan quota monitor, or a menu-bar token tracker that follows you across every machine? That combination is Wattson — see the [comparison below](#-同类工具对比--how-wattson-compares).

## ⚖️ 同类工具对比 · How Wattson compares

Wattson 不追求单点最强，而是把「多机 · 全历史 · 本地优先」这条组合做全。与各位优秀前辈相比（数据截至 2026-09，欢迎 PR 修订）：

| | **Wattson** | [ccusage](https://github.com/ccusage/ccusage) | [CodexBar](https://github.com/steipete/codexbar) | [openusage](https://github.com/robinebers/openusage) | [Tokdash](https://github.com/JingbiaoMei/tokdash) |
|---|---|---|---|---|---|
| 形态 | 菜单栏 + Web 看板 + REST API | CLI / statusline | 菜单栏（原生 Swift） | 菜单栏（原生 Swift） | 自托管 Web 看板（Python） |
| 多机聚合 | ✅ SSH 拉取，远端零安装零常驻 | — | — | — | ⚠️ 每台机器各装一个服务再互相联邦 |
| 用量历史分析 | ✅ 设备/工具/模型/项目 × 天/小时全切片 | ✅ 本机日/周/会话 | ⚠️ 额度为主 + 7/30 天花费估算 | ⚠️ 今日/30 天花费 | ✅ 另有会话钻取、热力图 |
| 订阅额度 | 16 账号（GLM/Codex/Claude/Cursor/WorkBuddy/Trae/Kimi/Gemini/Grok/Zed/Kiro/Codebuff/Factory/Copilot/OpenRouter/MiniMax） | — | ✅ 60+ 提供商 | ✅ 12 提供商 | ✅（部分需 opt-in 轮询） |
| 解析的工具数 | **42** | 19 | 以额度为主 | 花费统计 3 个 | ~24 |
| 中文生态（GLM/ZCode、WorkBuddy、Trae） | ✅ 用量 + 额度 + 远端镜像 | ZCode 用量 | z.ai 额度 | z.ai 额度 | — |
| 数据暴露面 | 仅 127.0.0.1 | 本地 CLI | 本地 | 本地 | 需开放只读 HTTP（官方建议 Tailscale） |

同赛道还有 [tokcat](https://github.com/handlecusion/tokcat)、[TokenEater](https://github.com/AThevon/TokenEater)、[ClaudeUsageBar](https://claudeusagebar.com/)、[phuryn/claude-usage](https://github.com/phuryn/claude-usage) 等菜单栏/单工具看板项目——均为单机形态。

> CodexBar 的 60+ 额度提供商与原生体积、ccusage 的社区与 CLI 生态，都是我们敬佩并持续借鉴的方向——如果你只在**单机**且只关心**额度**，它们是更轻的选择；一旦你有第二台机器，Wattson 开始不可替代。

### 🛰️ 多机聚合：Wattson vs 主流拼装方案

「多台机器的用量怎么汇总」是这个赛道的公认难题：[ccusage 官方至今没有原生多机支持](https://github.com/ccusage/ccusage/issues/222)，社区主流是三种拼装路线。Wattson 的 SSH 拉取式镜像是为这个问题原生设计的：

| | **Wattson SSH 镜像** | ccusage + Syncthing 共享目录 | ccusage + cron 上报云库（[DIY 教程](https://dev.to/ryantech00/how-i-track-claude-code-costs-across-multiple-pcs-13bl)） | [Tokdash](https://github.com/JingbiaoMei/tokdash) 每机部署联邦 |
|---|---|---|---|---|
| 远端要装什么 | **零安装**——系统自带 `ssh` + `rsync` + `sqlite3` | 每台装并常驻同步软件 | 每台装 Node + cron + 云数据库账号 | 每台装 Python 常驻服务 |
| 远端暴露面 | 无监听端口，只有 SSH 入站 | 全量 `~/.claude` 进共享目录 | 用量数据出本机入云端 | 每台开放只读 HTTP |
| 设备维度 | ✅ 原生（host 由镜像路径推断，可按设备切片） | ❌ 多目录合并解析，输出不区分设备 | 需自建 | ✅ |
| 数据一致性 | ✅ 单事务快照投影（~190MB 库 → ~2MB，增量轮 KiB 级） | ⚠️ 多机同时写有同步冲突风险，社区建议按设备分目录 | ✅ 但要自己保证口径 | ✅ |
| 维护面 | 一份 `agg.config.json` + 两个 LaunchAgent | N 台机器各配同步 | cron + 云库 + 自建看板三件套 | N 个常驻服务互相联邦 |

一句话：拼装方案把「同步」这个难题留给了用户，Wattson 把它做成了产品——远端零安装、零常驻、零监听，设备维度原生可切。

## 🧩 支持平台全景

### 📊 用量解析（本机，42 个工具，自动发现）

装了哪个工具、`~` 下有它的数据目录，看板就自动出现它——无需配置。名单来自 vendored 的 [codeburn](https://github.com/getagentseal/codeburn) 解析基座（升级 `codeburn/` 即扩展名单）：

| | | | | | |
|---|---|---|---|---|---|
| Claude Code 💳 | Codex ⭐💳 | Gemini | Cursor 💳 | Cursor Agent | Copilot |
| OpenCode | Crush | Zed | Warp | Droid | Grok Build |
| Kimi | Kimi Code | Qwen | DeepSeek Harness | ZCode ⭐💳 | WorkBuddy ⭐💳 |
| Devin | Goose | Forge | Kiro | Antigravity | Cline |
| Cline CLI | Roo Code | KiloCode | Codebuff | CodeWhale | Zerostack |
| Mux | Hermes Agent | IBM Bob | LingTai TUI | Mistral Vibe | OpenClaw |
| OpenClaude | Open Design | Pi | OMP | Quick Desktop | Vercel AI Gateway |

### 🛰️ 远端多机镜像（3 个工具）

远端设备经 `ssh` 拉取式同步，每 30 分钟一轮，单台失败不阻塞其它：

| 工具 | 远端数据 | 同步机制 |
|---|---|---|
| **ZCode** ⭐ | SQLite（本机实测 ~190MB） | 远端单事务 `ATTACH` 投影出解析所需的 3 张表 → **~2MB**，rsync 以旧镜像为增量基准 + 4KiB 页对齐拉回 |
| **Codex** ⭐ | jsonl 会话目录 | 目录级增量 rsync（`--delete` 跟随远端归档） |
| **WorkBuddy** ⭐ | SQLite | `VACUUM INTO` 一致性快照 → rsync 增量 |

### 🧾 订阅额度卡片（16 个账号）

| 账号 | 凭据来源（本机，自动） | 额度窗口 |
|---|---|---|
| **GLM Coding Plan**（ZCode） | `~/.zcode/v2/credentials.json`（AES-GCM 解密） | 5 小时窗口 + 周额度 |
| **Codex**（ChatGPT） | `~/.codex/auth.json`（受限域名自动走系统代理） | 5 小时窗口 + 周额度 |
| **Claude Code** | `~/.claude/.credentials.json` | 5 小时窗口 + 周额度 + 周额度（Sonnet） |
| **Cursor** | `~/.cursor/auth.json` 或 `CURSOR_ACCESS_TOKEN` | 5 小时窗口 + 周期额度 |
| **WorkBuddy** | `~/codeburn-agg/workbuddy-auth.json`（token 在钥匙串，需手动提供） | 周期额度 |
| **Trae** | `~/codeburn-agg/trae-auth.json` 或 `TRAE_ACCESS_TOKEN` | 周期额度 |
| **Kimi** | `~/.kimi-code/credentials/kimi-code.json` 或 `KIMI_CODE_API_KEY` | 周额度 + 速率窗口 |
| **Gemini**（oauth-personal） | `~/.gemini/oauth_creds.json`（过期自动刷新回写） | 按模型每日配额 |
| **Grok** | `~/.grok/auth.json` 或 `GROK_OAUTH_TOKEN` | 订阅周期额度（SuperGrok） |
| **Zed** | `ZED_ACCESS_TOKEN`+`ZED_USER_ID`（或 `ZED_KEYCHAIN=1` 读钥匙串） | 补全额度 + 账期进度 |
| **Kiro** | kiro-cli 本地 SQLite（`KIRO_ACCESS_TOKEN`+`KIRO_PROFILE_ARN` 可覆盖） | 周期额度（CodeWhisperer credits） |
| **Codebuff** | `~/.config/manicode/credentials.json` 或 `CODEBUFF_API_KEY` | 积分额度 + 周额度 |
| **Factory** | `~/.factory/.env` 或 `FACTORY_API_KEY` | 5 小时窗口 + 周额度 + 月度额度 |
| **Copilot** | `COPILOT_API_TOKEN`（GitHub OAuth token） | Premium 请求 + Chat（月度重置） |
| **OpenRouter** | `OPENROUTER_API_KEY` | 账户余额 + Key 限额 |
| **MiniMax** | `MINIMAX_API_KEY` / `MINIMAX_CODING_API_KEY`（`MINIMAX_REGION=cn` 切中国区） | 5 小时窗口 + 周额度 |

### 💻 操作系统与硬件

| 角色 | 要求 |
|---|---|
| 菜单栏客户端 | macOS 11+（Electron 37 声明的最低系统）· Apple Silicon（arm64）· 目标机**零依赖**（不需要 Node/python，服务由 Electron 内置 Node 托管） |
| 中心机（server + 看板） | macOS · Homebrew Node ≥ 22.13（或直接用客户端，免 Node） |
| 远端设备 | 任意 ssh 免密可达的 macOS / Linux · 只需系统 `ssh` + `rsync` + `sqlite3` |

> 图例：⭐ 支持远端多机镜像 · 💳 有订阅额度卡片

## 🚀 快速开始

**方式一：菜单栏客户端（推荐，全程 GUI）**

拿 [Releases](https://github.com/makamark/wattson-usage/releases) 里的 `Wattson-<版本>-arm64.dmg` 安装（或 `bash scripts/package-app.sh` 自建），首次运行自动弹出向导：探测本机工具 → 添加远端设备（自动验证 SSH 可达性与数据源）→ 端口/刷新间隔 → 一键启动。经即时通讯/AirDrop 分发的未签名包需先 `xattr -cr /Applications/Wattson.app`。

**方式二：脚本安装（launchd 常驻）**

```bash
git clone https://github.com/makamark/wattson-usage && cd wattson-usage
bash scripts/setup.sh                  # 交互式向导
# 或非交互：bash scripts/setup.sh --ssh desktop --yes
# 设备名≠ssh 别名时：--ssh workstation:desktop
bash scripts/install.sh                # 构建 + 首次镜像 + 装 LaunchAgents
open http://127.0.0.1:8317             # 首次冷启动约 1–2 分钟
```

**方式三：只用浏览器看板**

装好方式二后两个 LaunchAgent 开机自启：`com.wattson.mirror` 每 30 分钟拉远端，`com.wattson.server` 常驻聚合、每 30 分钟重解析，页面每 5 分钟自刷。

<details>
<summary><b>🏗️ 架构一页图</b></summary>

```
 本机（中心机）                                         远端设备（可多台）
 ───────────────────────────────────────              ──────────────────────
 本机活数据（42 工具自动发现）                          真实数据
   ~/.zcode/cli/db/db.sqlite                           ~/.zcode/cli/db/db.sqlite
   ~/.codex/sessions/…                                 ~/.codex/sessions/…
   ~/.workbuddy/workbuddy.db                           ~/.workbuddy/workbuddy.db
        │                                                    │
        │                                     com.wattson.mirror（launchd，每 30 分钟）
        │                                     sync/mirror.sh 按 agg.config.json 循环多设备：
        │                                       · zcode：远端 sqlite3 单事务 ATTACH 投影
        │                                         只导出解析所需 3 张表（~190MB → ~2MB）
        │                                       · workbuddy：VACUUM INTO 一致性快照
        │                                       · rsync 增量拉回（旧镜像作基准 +
        │                                         --block-size=4096 与 SQLite 页对齐）
        │                                       · codex sessions：jsonl 目录级增量
        │                                       单设备失败/不可达不阻塞其它设备
        │                                                    │
        │                                                    ▼
        │                                     ~/codeburn-agg/mirror/<设备名>/
        │                                       zcode/ workbuddy/ codex/
        │                                                    │
        ▼                                                    ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │ agg-server（com.wattson.server，launchd 常驻）                    │
 │   server/src/main.ts · node --import tsx · 127.0.0.1:8317        │
 │   codeburn 解析管线（vendored codeburn/，增量缓存）                │
 │     → UsageRow[]（host 由数据源路径推断：本机=hostname，           │
 │       mirror 路径=设备名）→ /api/* + 静态托管 web/dist             │
 └─────────────────────────────────────────────────────────────────┘
        │
        ▼
 浏览器 http://127.0.0.1:8317 / 菜单栏客户端内嵌窗口（web/：Vite + ECharts）
```

同步语义的量化评估（原整库快照每轮 ~180MB 全量重传 → 现在首轮 ~2MB、增量轮 KiB 级）见 `docs/mirror-volume.md`。
</details>

<details>
<summary><b>⚙️ 配置与环境变量</b></summary>

统一配置 `agg.config.json`（已 gitignore，模板 `agg.config.example.json`；客户端打包态在 `~/codeburn-agg/`）：

```json
{
  "server": { "port": 8317, "refreshMinutes": 30 },
  "devices": [
    { "name": "laptop", "local": true },
    { "name": "desktop", "ssh": "desktop" }
  ]
}
```

- `devices`：`local: true` 代表本机；远端每台 `{ "name", "ssh" }`，`name` = 镜像目录名与看板「设备」维度值
- `scripts/gen-config.py`（或客户端）据此生成 `~/.config/codeburn/devices.json`；改配置后重跑 `bash scripts/install.sh`
- 本机数据零配置：自动按 hostname 短名挂载；镜像文件 host 由路径前缀推断

| 环境变量 | 作用 | 默认 |
|---|---|---|
| `CODEBURN_AGG_PORT` | 监听端口（固定绑 127.0.0.1） | `8317` |
| `CODEBURN_AGG_REFRESH_MIN` | 重解析间隔（分钟） | `30` |
| `CODEBURN_AGG_WEB` | 静态目录覆盖 | 仓库内 `web/dist` |

**价格修正**（自部署/内部模型名默认 $0 计）：

```bash
node codeburn/dist/cli.js model-alias <内部模型名> <官方模型名>   # 映射到有价目的模型
node codeburn/dist/cli.js model-flat-rate <模型名>               # 声明为订阅/包月，$0 合理
```
</details>

<details>
<summary><b>🔌 API 一览（127.0.0.1:8317）</b></summary>

聚合端点共享同一套查询条件：`range=24h|7d|30d|all` 与 `hosts=/tools=/models=/projects=`（逗号分隔多值）；先过滤再聚合，看板各区块口径一致；非法取值返回 400。

| 端点 | 说明 |
|---|---|
| `GET /api/status` | `{localHost, fetchedAt, lastSuccessAt, refreshing, errors, recordCount, instanceId, configPath, port}` |
| `GET /api/overview?…` | 总 Token/成本/调用数、缓存命中率、活跃天数、按设备/工具汇总（`allTime` 全时段；`estimatedCost` 估算部分） |
| `GET /api/series?bucket=day\|hour&group=…&metric=tokens\|cost\|calls` | 主图时间序列（分组超 12 合并「其他」，桶上限 400） |
| `GET /api/matrix?rows=…` | 行×模型 Token 热力矩阵 |
| `GET /api/models?…` | 模型明细表（按 token 总量降序） |
| `GET /api/plan` | 订阅额度（见上表 16 账号；TTL 5 分钟，凭据不出服务端） |
| `POST /api/refresh` | 触发后台全量重解析，立即返回 202 |

**LaunchAgent 启停**：`launchctl load/unload ~/Library/LaunchAgents/com.wattson.{server,mirror}.plist`，日志在 `~/codeburn-agg/{server,mirror}.log`；手动前台调试 `cd server && npx tsx src/main.ts`；客户端开发 `cd app && npm run dev`。
</details>

<details>
<summary><b>🧯 已知限制与目录速览</b></summary>

**已知限制**

1. 钻取为聚合口径（先过滤再聚合），时间窗钻取到会话明细未做
2. 订阅额度是官方接口只读展示；凭据缺失的账号自动隐藏，不影响用量看板
3. workbuddy 用量是会话级估算，粒度粗于 zcode/codex
4. 成本按 LiteLLM 价折算，与实际套餐扣减无关；真实余量看额度卡片
5. 远端数据最长 30 分钟延迟；远端离线时该轮 skipped，看板继续显示旧快照并标注数据时间；镜像是一致性快照非活库
6. codex 按文件内增量记账（防 resume/fork 重复计费），与 codex 自报账面累计口径不同（量级差已按 fork/resume 继承定量归因）
7. `codeburn/` 是 vendored 快照：覆盖新版源码后 `npm ci && npm run build` 即升级
8. 只解析已完成调用的用量行，进行中的轮次下一轮刷新才出现

**目录速览**

```
app/        菜单栏客户端 Wattson（Electron：托盘小窗/看板窗口/初始化向导 + 内嵌 agg-server）
codeburn/   vendored 用量解析基座（42 工具）
server/     agg-server（TypeScript，tsx 直跑）
web/        看板前端（Vite + ECharts）
sync/       mirror.sh 多设备镜像脚本 + mirror.test.sh 桩测试
templates/  LaunchAgent 模板    scripts/  setup/install/package-app/gen-config
docs/       镜像体积评估（mirror-volume.md）· README 截图素材
```
</details>

## 🙏 开源引用与致谢

### 直接内嵌 / 依赖的项目

| 项目 | 许可证 | 在本项目中承担的角色 |
|---|---|---|
| [codeburn](https://github.com/getagentseal/codeburn) | MIT | **核心解析基座**，vendored 于 `codeburn/`：42 种 AI 工具的会话发现与用量解析（SQLite/jsonl/zstd）、增量会话缓存与去重、模型定价口径（reasoning-in-output 去重的 billable 计算）、多设备数据根。`server/src/aggregate.ts` 直接复用其 `calculateCost` / `billableOutputTokens`。其第三方声明见 `codeburn/THIRD_PARTY_NOTICES.md` |
| [LiteLLM](https://github.com/BerriAI/litellm) 定价数据 | MIT | codeburn 打包的模型→价格表，成本估算的价目来源 |
| [Apache ECharts](https://echarts.apache.org/) | Apache-2.0 | 看板主图（堆叠时间序列）与 host×model 热力矩阵 |
| [Electron](https://www.electronjs.org/) / [electron-builder](https://www.electron.build/) | MIT | 菜单栏客户端与 .app/.dmg 打包 |
| [Vite](https://vitejs.dev/) | MIT | 看板前端构建 |
| [TypeScript](https://www.typescriptlang.org/) | Apache-2.0 | 全仓语言 |
| [tsx](https://github.com/privatenumber/tsx) | MIT | server 侧 TS 直跑加载器（开发态与打包内嵌态共用） |
| [Vitest](https://vitest.dev/) | MIT | server 单元测试 |
| [undici](https://github.com/nodejs/undici) | MIT | 订阅额度轮询 HTTP 客户端；`ProxyAgent` 支持受限域名走系统代理 |
| [Node.js](https://nodejs.org/) | MIT 等 | agg-server 运行时（打包态由 Electron 内置 Node 托管） |
| SQLite / rsync / OpenSSH（macOS 系统自带） | Public Domain / GPL-3.0 / 多许可 | 远端零安装同步栈的全部依赖 |

### 借鉴的思路与算法

- **rsync 滚动校验增量算法**（Andrew Tridgell 的[技术报告](https://rsync.samba.org/tech_report/node4.html)）：`sync/mirror.sh` 先把旧镜像复制为临时目标作增量基准（避免「目标不存在 → 无基准 → 全量重传」），并用 `--block-size=4096` 对齐 SQLite 页；实测与权衡见 `docs/mirror-volume.md`
- **SQLite 一致性快照**：`VACUUM INTO`（workbuddy）与单事务 `ATTACH` 投影（zcode 只导出解析器实际消费的 3 张表，约 190MB → 约 2MB），避免拷贝带 WAL 的活库（[官方 backup 语义](https://www.sqlite.org/backup.html)）
- **「数据投影 + 中心解析」**：远端只交付最小数据面，解析/计价/聚合全部在本机 codeburn 管线完成——解析器升级可回溯修正全部历史，远端保持零安装
- **增量会话缓存与去重键**（codeburn 设计）：按调用粒度 dedup，防 resume/fork 会话重复计费
- **拉取式多设备同步**：pull-based、per-设备锁、临时文件 + 原子 `mv` 替换、`ROUND RESULT` 机器可读汇总行、单设备失败不阻塞其它——全部只用 POSIX sh + 系统工具
- **凭据只读不出域**：订阅额度走各家官方只读接口，凭据只在服务端内存解密，不落看板、不回传

## 📄 License

[MIT](LICENSE)。`codeburn/` 为 vendored 的独立项目，版权与许可以其目录内 `LICENSE` / `THIRD_PARTY_NOTICES.md` 为准。
