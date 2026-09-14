// app/src/main.ts — Wattson 菜单栏客户端主进程。
// 职责：
//   1) 托管 agg-server：优先复用已在监听的外部实例（如 launchd 装的），否则以子进程启动
//      （打包态用 Electron 自带 Node 跑 tsx，server/codeburn/web/dist 全部内嵌 Resources）；
//   2) 菜单栏托盘：标题=近 24h Token，左键弹状态栏小窗，右键菜单；
//   3) 完整看板窗口（加载内嵌 server 托管的 web/dist）；
//   4) 初始化/设置向导：多机设备（SSH 探测）+ 端口/刷新 → 写 agg.config.json →
//      派生 ~/.config/codeburn/devices.json → 首次同步 →（重）启服务；
//   5) 远端镜像：应用运行期间每 30 分钟一轮（Mirror）。
import { app, BrowserWindow, Tray, Menu, screen, nativeImage, ipcMain, shell } from 'electron'
import { spawn, execFile, type ChildProcess } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import {
  CONFIG_PATH, DEVICES_FILE, MIRROR_SCRIPT, REPO_ROOT,
  DEVICE_NAME_RE, validSshTarget,
  genDevicesJson, hasConfig, localName, probeLocalTools,
  readConfig, writeConfig, configuredPort, type Config, type Device,
} from './config'
import { Mirror, type MirrorState } from './mirror'

if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  void main()
}

const LOG_DIR = join(homedir(), 'Library', 'Logs', 'Wattson')
const LOG_FILE = join(LOG_DIR, 'app.log')
function log(msg: string): void {
  const line = `[${new Date().toLocaleString('zh-CN', { hour12: false })}] ${msg}`
  console.log(line)
  try { mkdirSync(LOG_DIR, { recursive: true }); appendFileSync(LOG_FILE, line + '\n') } catch { /* 日志失败不致命 */ }
}

/** 与 web/src/format.ts 的 fmtTokens 同口径（托盘标题用） */
const fmtTokens = (n: number): string =>
  n >= 1e9 ? (n / 1e9).toFixed(2) + 'B'
    : n >= 1e6 ? (n / 1e6).toFixed(2) + 'M'
    : n >= 1e3 ? (n / 1e3).toFixed(1) + 'K'
    : String(n)

// ---------- 聚合状态（推送给小窗/向导渲染层） ----------
type Phase = 'starting' | 'external' | 'ready' | 'error'
/** 环比用 KPI 子集（server /api/overview?compare=previous 的 prev 字段） */
type KpiPrev = { totalTokens: number; totalCost: number | null; calls: number; cacheHitRate: number | null; activeDays: number }
type Overview = {
  totalTokens: number; totalCost: number | null; calls: number; cacheHitRate: number | null
  activeDays: number; byHost: Record<string, { tokens: number; cost: number | null }>
  byTool: Record<string, { tokens: number; cost: number | null }>; allTime?: unknown; fetchedAt?: number; errors?: string[]
  prev?: KpiPrev | null
} | null
type Status = {
  localHost: string; fetchedAt: number; refreshing: boolean; errors: string[]; recordCount: number
  // 握手信息（server /api/status 提供）：外部实例接管前核对配置来源，避免「端口通但
  // 配置不同源」的静默错配
  configPath?: string; instanceId?: string; port?: number
} | null

/** 订阅额度快照（/api/plan，结构见 server/src/quotas/types.ts 的 QuotaSnapshot） */
type QuotaWindow = {
  key: string; label: string
  usedPercent?: number | null; total?: number | null; used?: number | null; remaining?: number | null
  percentage: number | null; nextResetAt: number | null
}
type QuotaAccount = {
  kind: string; label: string
  available: boolean; unavailableReason: string | null; error: string | null
  planName: string | null; windows: QuotaWindow[]
}
type QuotaState = { accounts: QuotaAccount[] } | null

/** 小窗 KPI 时间范围（今日/24h/7d/30d）；24h 时直接复用 overview，不额外请求 */
type PopupRange = '24h' | 'today' | '7d' | '30d'
const POPUP_RANGES: PopupRange[] = ['24h', 'today', '7d', '30d']

const state = {
  phase: 'starting' as Phase,
  phaseError: '',
  startingSince: Date.now(),
  port: configuredPort(readConfig()),
  overview: null as Overview,
  popupRange: '24h' as PopupRange,
  popupOverview: null as Overview,
  status: null as Status,
  plan: null as QuotaState,
  mirror: { running: false, lastAt: null, lastCode: null } as MirrorState,
  configured: hasConfig(),
}
const base = (): string => `http://127.0.0.1:${state.port}`

// ---------- 窗口 ----------
let tray: Tray | null = null
let popup: BrowserWindow | null = null
let dashWin: BrowserWindow | null = null
let wizWin: BrowserWindow | null = null

const preloadPath = () => join(__dirname, 'preload.js')

function pushState(): void {
  const payload = { ...state }
  for (const win of [popup, wizWin]) {
    if (win && !win.isDestroyed()) win.webContents.send('state', payload)
  }
}

// ---------- agg-server 托管 ----------
let serverChild: ChildProcess | null = null
let serverChildOwned = false
let ensurePromise: Promise<void> | null = null

async function fetchJson(path: string, timeoutMs: number, init?: RequestInit): Promise<unknown | null> {
  try {
    const ac = new AbortController()
    const timer = setTimeout(() => ac.abort(), timeoutMs)
    const res = await fetch(base() + path, { ...init, signal: ac.signal })
    clearTimeout(timer)
    if (!res.ok) return null
    return await res.json()
  } catch { return null }
}

const probe = (): Promise<Status> => fetchJson('/api/status', 2500) as Promise<Status>

/** 幂等：外部可复用→adopt；否则 spawn 子进程并等它开始监听（冷启动全量解析约 1–2 分钟） */
function ensureServer(): Promise<void> {
  if (!ensurePromise) {
    ensurePromise = doEnsure().catch((err: unknown) => {
      log(`ensureServer 异常: ${err instanceof Error ? err.message : String(err)}`)
    }).finally(() => { /* 保持在 ready/external；error 时允许 retry 重入 */ })
  }
  return ensurePromise
}

async function doEnsure(): Promise<void> {
  const external = await probe()
  if (external) {
    // 握手核对：外部实例若指向别的配置文件（如另一份 agg.config.json），
    // 端口/设备改动互不相通，明说而不是静默错配
    if (external.configPath && external.configPath !== CONFIG_PATH) {
      log(`警告：复用的外部 agg-server 使用不同配置文件（${external.configPath} ≠ ${CONFIG_PATH}），配置改动可能互不相通`)
    }
    state.phase = 'external'
    state.phaseError = ''
    pushState()
    log(`复用已运行的 agg-server（${base()}，外部实例）`)
    void pollAll()
    return
  }
  if (!state.configured) {
    state.phase = 'error'
    state.phaseError = '尚未完成初始化配置'
    pushState()
    return
  }
  spawnServerChild()
  if (!serverChild) return
  state.phase = 'starting'
  state.startingSince = Date.now()
  state.phaseError = ''
  pushState()
  const deadline = Date.now() + 6 * 60 * 1000
  while (Date.now() < deadline) {
    await sleep(2000)
    if ((state.phase as Phase) === 'error') return // 子进程已退出，错误细节在 exit handler 里
    if (await probe()) {
      state.phase = 'ready'
      pushState()
      log(`内嵌 agg-server 就绪（${base()}）`)
      void pollAll()
      return
    }
  }
  // 超时必须回收旧子进程：否则端口被占、引用悬挂，重试会再 spawn 一个孤儿
  if (serverChild) {
    const stuck = serverChild
    serverChild = null
    serverChildOwned = false
    stuck.kill()
    log('启动超时，已终止未就绪的子进程')
  }
  state.phase = 'error'
  state.phaseError = '等待聚合服务就绪超时（6 分钟）— 详见日志'
  pushState()
}

function spawnServerChild(): void {
  const serverDir = join(REPO_ROOT, 'server')
  const env: NodeJS.ProcessEnv = { ...process.env, AGG_CONFIG: CONFIG_PATH }
  let cmd: string
  if (app.isPackaged) {
    // 打包态不依赖系统 Node：用 Electron 自带 Node（ELECTRON_RUN_AS_NODE）跑 tsx；
    // cwd=server 使 --import tsx 解析到 server/node_modules
    env['ELECTRON_RUN_AS_NODE'] = '1'
    cmd = process.execPath
  } else {
    const brewNode = '/opt/homebrew/bin/node'
    cmd = existsSync(brewNode) ? brewNode : 'node'
  }
  log(`启动内嵌 agg-server: ${cmd} --import tsx src/main.ts（cwd=${serverDir}）`)
  let child: ChildProcess
  try {
    child = spawn(cmd, ['--import', 'tsx', 'src/main.ts'], { cwd: serverDir, env, stdio: ['ignore', 'pipe', 'pipe'] })
  } catch (err) {
    state.phase = 'error'
    state.phaseError = `无法启动聚合服务: ${err instanceof Error ? err.message : String(err)}`
    pushState()
    return
  }
  serverChild = child
  serverChildOwned = true
  const tail: string[] = []
  const pump = (stream: NodeJS.ReadableStream | null) => {
    if (!stream) return
    stream.setEncoding('utf8')
    stream.on('data', (chunk: string) => {
      for (const line of chunk.split('\n')) {
        if (!line.trim()) continue
        log(`[server] ${line}`)
        tail.push(line)
        if (tail.length > 40) tail.shift()
      }
    })
  }
  pump(child.stdout)
  pump(child.stderr)
  child.on('error', (err) => {
    log(`server 子进程 spawn 失败: ${err.message}`)
    if (serverChild === child) {
      state.phase = 'error'
      state.phaseError = `无法启动聚合服务: ${err.message}`
      pushState()
    }
  })
  child.on('exit', (code, signal) => {
    log(`server 子进程退出 code=${code} signal=${signal}`)
    if (serverChild === child) {
      serverChild = null
      serverChildOwned = false // 所有权随进程消亡：保存配置后的重启分支据此能真正拉起新实例
      if (state.phase !== 'error') {
        state.phase = 'error'
        state.phaseError = `聚合服务已退出（code=${code}）\n${tail.slice(-12).join('\n')}`
        pushState()
      }
    }
  })
}

/** 设置向导保存后调用：内嵌实例重启以吃到新配置；外部实例不动（用户自管，向导里提示） */
async function restartEmbeddedServer(): Promise<void> {
  state.phase = 'starting'
  state.startingSince = Date.now()
  state.phaseError = ''
  state.overview = null
  state.status = null
  pushState()
  const child = serverChild
  if (child) {
    await new Promise<void>((resolve) => {
      child.once('exit', () => resolve())
      child.kill()
      setTimeout(resolve, 3000) // 兜底：3 秒还没退就继续（端口可能仍被占，probe 会再等）
    })
  }
  serverChild = null
  serverChildOwned = false
  ensurePromise = null
  state.port = configuredPort(readConfig())
  await ensureServer()
  // 端口变化时已打开的看板窗口要跟着重新导航，否则一直打旧端口
  if (dashWin && !dashWin.isDestroyed()) {
    await dashWin.loadURL(base() + '/').catch(() => undefined)
  }
}

// ---------- 数据轮询 ----------
let statusFailStreak = 0
async function pollOverview(): Promise<void> {
  if (state.phase !== 'ready' && state.phase !== 'external') return
  // 24h 供托盘标题与默认视图；compare=previous 附带上一等长窗口 KPI（小窗环比箭头）
  const o = await fetchJson('/api/overview?range=24h&compare=previous', 5000) as Overview
  if (o) {
    state.overview = o
    updateTrayTitle()
  }
  // 小窗切到其它范围时按需补拉；失败软处理（保留上次数据，不闪空）
  if (state.popupRange !== '24h') {
    const po = await fetchJson(`/api/overview?range=${state.popupRange}&compare=previous`, 5000) as Overview
    if (po) state.popupOverview = po
  } else {
    state.popupOverview = null
  }
  pushState()
}

async function pollStatus(): Promise<void> {
  if (state.phase !== 'ready' && state.phase !== 'external') return
  const s = await probe()
  if (s) {
    statusFailStreak = 0
    state.status = s
  } else {
    // 短暂抖动忽略；连续 3 次失联（如外部 launchd 服务被停）→ 尝试自己拉起
    if (++statusFailStreak >= 3) {
      statusFailStreak = 0
      log('聚合服务连续失联，尝试重新托管')
      state.phase = 'starting'
      state.startingSince = Date.now()
      state.status = null
      pushState()
      ensurePromise = null
      void ensureServer()
      return
    }
  }
  pushState()
}

async function pollPlan(): Promise<void> {
  if (state.phase !== 'ready' && state.phase !== 'external') return
  const p = await fetchJson('/api/plan', 5000) as QuotaState
  if (p) {
    state.plan = p
    pushState()
  }
}

async function pollAll(): Promise<void> {
  await Promise.all([pollStatus(), pollOverview(), pollPlan()])
}

function startPolling(): void {
  setInterval(() => void pollStatus(), 20 * 1000)
  setInterval(() => void pollOverview(), 3 * 60 * 1000)
  // 额度窗口随时间推进/重置，不能只在服务就绪时拉一次；节奏对齐服务端 plan 的 5 分钟 TTL
  setInterval(() => void pollPlan(), 5 * 60 * 1000)
}

/** 触发后台全量重解析（202 立即返回），随后快轮询状态直至解析结束再拉一次概览 */
async function refreshData(): Promise<{ ok: boolean }> {
  if (state.phase !== 'ready' && state.phase !== 'external') return { ok: false }
  try {
    const ac = new AbortController()
    setTimeout(() => ac.abort(), 5000)
    const res = await fetch(base() + '/api/refresh', { method: 'POST', signal: ac.signal })
    if (!res.ok) return { ok: false }
  } catch { return { ok: false } }
  void fastPollUntilSettled()
  return { ok: true }
}

// ---------- 镜像 ----------
const mirror = new Mirror(
  (line) => {
    log(line)
    if (wizWin && !wizWin.isDestroyed()) wizWin.webContents.send('mirror-log', line)
  },
  (s) => { state.mirror = s; pushState() },
  // 每轮现读配置：向导里改完设备下一轮同步即生效，无需重启应用
  () => (readConfig()?.devices ?? [])
    .filter(d => !d.local && typeof d.ssh === 'string' && d.ssh)
    .map(d => `${d.name}\t${d.ssh}`)
    .join('\n'),
  // 同步 → 采集依赖链：一轮完整结束（exit 0）后触发一次后台重解析，
  // 否则刚拉回的远端数据要等下一个 30 分钟采集节拍才进看板
  (code) => { if (code === 0) void refreshData() },
)

// ---------- 托盘 ----------
function updateTrayTitle(): void {
  if (!tray) return
  const o = state.overview
  const title = o ? fmtTokens(o.totalTokens) : (state.phase === 'starting' || state.phase === 'ready' ? '…' : '')
  tray.setTitle(title)
  tray.setToolTip(o
    ? `近 24 小时：${fmtTokens(o.totalTokens)} tokens · ${o.calls.toLocaleString('zh-CN')} 次调用`
    : 'Wattson（无数据）')
}

function trayMenu(): Menu {
  const template: Array<Electron.MenuItemConstructorOptions> = [
    { label: '打开完整看板', click: () => void openDashboard() },
    { label: '刷新数据', click: () => void refreshData() },
    { type: 'separator' },
    { label: '设置…（设备与初始化）', click: () => openWizard() },
    { label: '立即同步远端', click: () => { if (!mirror.run()) log('镜像已在进行中，忽略本次手动触发') } },
  ]
  if (app.isPackaged) {
    template.push(
      { type: 'separator' },
      {
        label: '登录时启动',
        type: 'checkbox',
        checked: app.getLoginItemSettings().openAtLogin,
        click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
      },
    )
  }
  template.push(
    { type: 'separator' },
    { label: '查看日志…', click: () => void shell.openPath(LOG_FILE).then(() => undefined).catch(() => undefined) },
    { label: `退出 ${app.name}`, click: () => app.quit() },
  )
  return Menu.buildFromTemplate(template)
}

function createTray(): void {
  const icon = nativeImage.createFromPath(join(__dirname, '..', 'build', 'trayTemplate.png'))
  icon.setTemplateImage(true)
  tray = new Tray(icon)
  tray.setTitle('…')
  tray.setToolTip('Wattson')
  tray.on('click', () => togglePopup())
  tray.on('right-click', () => tray?.popUpContextMenu(trayMenu()))
}

// ---------- 状态栏小窗 ----------
function ensurePopup(): BrowserWindow {
  if (popup && !popup.isDestroyed()) return popup
  popup = new BrowserWindow({
    width: 384, height: 560, show: false, frame: false, resizable: false, fullscreenable: false,
    skipTaskbar: true, alwaysOnTop: true, useContentSize: true,
    backgroundColor: '#111318',
    webPreferences: { preload: preloadPath(), contextIsolation: true, nodeIntegration: false },
  })
  popup.loadFile(join(__dirname, 'popup', 'index.html'))
  popup.on('blur', () => { if (popup && !popup.webContents.isDevToolsOpened()) popup.hide() })
  popup.on('closed', () => { popup = null })
  return popup
}

function togglePopup(): void {
  const win = ensurePopup()
  if (win.isVisible()) { win.hide(); return }
  const iconRect = tray?.getBounds()
  const size = win.getContentSize()
  const work = screen.getPrimaryDisplay().workArea
  let x = iconRect ? Math.round(iconRect.x + iconRect.width / 2 - size[0]! / 2) : Math.round(work.x + 20)
  x = Math.min(Math.max(x, work.x + 8), work.x + work.width - size[0]! - 8)
  const y = iconRect ? Math.round(iconRect.y + iconRect.height + 5) : work.y + 8
  win.setPosition(x, y, false)
  win.showInactive()
  win.focus()
}

// ---------- 完整看板窗口 ----------
async function openDashboard(): Promise<void> {
  if (dashWin && !dashWin.isDestroyed()) { dashWin.focus(); return }
  dashWin = new BrowserWindow({
    width: 1280, height: 860, backgroundColor: '#111318', title: 'Wattson',
    webPreferences: { contextIsolation: true },
  })
  dashWin.on('closed', () => { dashWin = null })
  await ensureServer()
  if (state.phase === 'error' && !state.configured) { openWizard(); dashWin.close(); return }
  await dashWin.loadURL(base() + '/')
}

// ---------- 设置/初始化向导窗口 ----------
function openWizard(): BrowserWindow {
  if (wizWin && !wizWin.isDestroyed()) { wizWin.focus(); return wizWin }
  wizWin = new BrowserWindow({
    width: 780, height: 680, backgroundColor: '#111318', title: 'Wattson · 设置',
    webPreferences: { preload: preloadPath(), contextIsolation: true, nodeIntegration: false },
  })
  wizWin.loadFile(join(__dirname, 'wizard', 'index.html'))
  wizWin.on('closed', () => { wizWin = null })
  return wizWin
}

// ---------- SSH 探测（与 scripts/setup.sh add_remote 同口径） ----------
function probeSsh(dest: string): Promise<{ ok: boolean; tools: string[]; missing: string[]; error?: string }> {
  // 可达性只由 ssh 本身成败决定；远端按路径显式打印 src:<工具> / missing:<命令> 行（口径同 scripts/setup.sh）
  const script = '[ -e "$HOME/.zcode/cli/db/db.sqlite" ] && echo src:zcode; [ -d "$HOME/.codex/sessions" ] && echo src:codex; [ -e "$HOME/.workbuddy/workbuddy.db" ] && echo src:workbuddy; command -v sqlite3 >/dev/null || echo missing:sqlite3; command -v rsync >/dev/null || echo missing:rsync; true'
  return new Promise((resolve) => {
    execFile('/usr/bin/ssh', ['-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', dest, script],
      { timeout: 20 * 1000, encoding: 'utf8' }, (err, stdout) => {
        if (err) {
          resolve({ ok: false, tools: [], missing: [], error: 'ssh 不可达（需免密登录，检查 ~/.ssh/config）' })
          return
        }
        const tools: string[] = [], missing: string[] = []
        for (const line of stdout.split('\n')) {
          const m = /^src:(.+)$/.exec(line.trim())
          if (m) tools.push(m[1]!)
          const w = /^missing:(.+)$/.exec(line.trim())
          if (w) missing.push(w[1]!)
        }
        resolve({ ok: true, tools: [...new Set(tools)], missing })
      })
  })
}

// ---------- IPC ----------
function registerIpc(): void {
  ipcMain.handle('popup:open-dashboard', () => void openDashboard())
  ipcMain.handle('popup:open-settings', () => { openWizard(); return true })
  ipcMain.handle('popup:retry-server', () => {
    if (state.phase === 'error') {
      ensurePromise = null
      void ensureServer()
    }
    return true
  })
  ipcMain.handle('popup:refresh-data', () => refreshData())
  ipcMain.handle('popup:set-range', (_e, r: unknown) => {
    if (typeof r === 'string' && (POPUP_RANGES as string[]).includes(r) && state.popupRange !== r) {
      state.popupRange = r as PopupRange
      state.popupOverview = null // 先清掉旧范围数据，等新数据到位再渲染
      pushState()
      void pollOverview()
    }
    return true
  })

  ipcMain.handle('wiz:get', () => ({
    configPath: CONFIG_PATH, devicesFile: DEVICES_FILE, mirrorScript: MIRROR_SCRIPT,
    config: readConfig(), localName: localName(), localTools: probeLocalTools(),
    state: { ...state },
  }))
  ipcMain.handle('wiz:probe-ssh', (_e, dest: unknown) =>
    typeof dest === 'string' && dest.trim() ? probeSsh(dest.trim()) : { ok: false, tools: [], missing: [], error: '参数错误' })
  ipcMain.handle('wiz:save', (_e, cfg: unknown) => applySavedConfig(cfg as Config))
  ipcMain.handle('wiz:run-mirror', () => mirror.run())
}

/** 校验+落盘+生效。返回给向导的结果（错误消息直接展示）。 */
async function applySavedConfig(cfg: Config): Promise<{ ok: boolean; error?: string; restarted?: string }> {
  if (!cfg || typeof cfg !== 'object') return { ok: false, error: '配置格式错误' }
  const server = cfg.server ?? {}
  const port = Number(server.port ?? 8317)
  const refresh = Number(server.refreshMinutes ?? 30)
  if (!Number.isInteger(port) || port < 1 || port > 65535) return { ok: false, error: `端口不合法：${server.port}` }
  if (!Number.isFinite(refresh) || refresh < 1) return { ok: false, error: `刷新间隔不合法：${server.refreshMinutes}` }
  const devices: Device[] = [{ name: localName(), local: true }]
  const seen = new Set<string>([localName()])
  for (const d of cfg.devices ?? []) {
    if (!d || typeof d !== 'object' || d.local) continue
    const name = String(d.name ?? '').trim()
    const ssh = String(d.ssh ?? '').trim()
    if (!name || !ssh) return { ok: false, error: '远端设备需要同时填写设备名与 SSH 目标' }
    // 设备名进镜像目录/远端临时文件名/看板维度，SSH 目标是 ssh 命令行参数：
    // 受限字符集 + 禁止 - 开头（防选项注入），与 sync/mirror.sh 的校验同口径
    if (!DEVICE_NAME_RE.test(name)) return { ok: false, error: `设备名仅允许字母数字与 . _ -（1–64 字符）：${name}` }
    if (!validSshTarget(ssh)) return { ok: false, error: `SSH 目标不合法（不能以 - 开头，仅允许字母数字与 . _ @ % : + -）：${ssh}` }
    if (seen.has(name)) return { ok: false, error: `设备名重复：${name}` }
    seen.add(name)
    devices.push({ name, ssh })
  }
  // 重建配置时保留 server 节里 App 表单不含但 server 支持的字段（如 webDist），
  // 否则一次保存就把用户手写的字段静默抹掉
  const prevServer = readConfig()?.server ?? {}
  const full: Config = {
    server: {
      port,
      refreshMinutes: Math.round(refresh),
      ...(prevServer.webDist ? { webDist: prevServer.webDist } : {}),
    },
    devices,
  }
  try {
    writeConfig(full)
    genDevicesJson(full)
  } catch (err) {
    return { ok: false, error: `写入配置失败: ${err instanceof Error ? err.message : String(err)}` }
  }
  state.configured = true
  const portChanged = port !== state.port
  log(`配置已保存（${CONFIG_PATH}，${devices.length - 1} 台远端）`)
  // 镜像与（内嵌）服务按新配置生效；外部实例（launchd）不替用户重启，向导负责提示
  mirror.startSchedule()
  let restarted: string
  if (serverChildOwned) {
    // 不 await：冷启动等待可达分钟级，阻塞 invoke 会让向导卡在「保存」上；
    // 重启进度由 onState（phase: starting→ready）驱动向导步骤打勾
    void restartEmbeddedServer()
    restarted = 'embedded'
  } else if (state.phase === 'external') {
    // 外部实例仍监听旧端口：连接目标保持实际端口不动，待用户重启外部服务后
    // pollStatus 会继续打旧端口；配置里的新端口在重启前不应生效
    restarted = portChanged ? 'kept-external-port-changed' : 'kept-external'
  } else {
    state.port = port
    ensurePromise = null
    void ensureServer()
    restarted = 'embedded'
  }
  pushState()
  return { ok: true, restarted }
}

async function fastPollUntilSettled(): Promise<void> {
  for (let i = 0; i < 240; i++) {
    await sleep(5000)
    await pollStatus()
    if (state.status && !state.status.refreshing) break
  }
  await pollOverview()
  // 刷新数据后订阅额度也要跟上（服务端 plan 有 5 分钟 TTL，重拉即可拿到新快照）
  await pollPlan()
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

// ---------- 生命周期 ----------
async function main(): Promise<void> {
  app.on('second-instance', () => { void openDashboard() })
  app.dock?.hide()
  await app.whenReady()

  createTray()
  registerIpc()

  if (!hasConfig()) {
    log(`未找到配置（${CONFIG_PATH}），打开初始化向导`)
    openWizard()
  } else {
    // 每次启动重派生 devices.json，保证镜像根与配置一致（幂等）
    const cfg = readConfig()
    if (cfg) genDevicesJson(cfg)
    mirror.startSchedule()
  }
  void ensureServer()
  startPolling()
  // 启动即跑首轮同步：完成后经 onRoundDone 触发采集，避免「首次同步完成但
  // 看板仍缺远端数据」（此前首轮要等 30 分钟定时器 + 独立采集节拍对齐）
  mirror.run()

  // 仅供开发调试：环境变量打开时自动弹出小窗（CDP 截图验收用）
  if (process.env['UV_AUTO_POPUP'] === '1') setTimeout(() => togglePopup(), 1500)

  app.on('window-all-closed', () => { /* 托盘常驻，不退出 */ })
  app.on('before-quit', () => {
    mirror.stop()
    serverChild?.kill()
  })
  // kill/launchd 场景下 SIGTERM 默认硬退出不走 before-quit，会遗留 server 子进程
  process.on('SIGTERM', () => app.quit())
}
