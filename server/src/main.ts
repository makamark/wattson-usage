// server/src/main.ts — agg-server entry: collector + HTTP API + scheduler +
// static hosting of web/dist on 127.0.0.1:<port> (default 8317).
//
// Ordering follows the brief: the first (possibly cold, minutes-long) refresh
// completes BEFORE the server starts listening, so the startup log line reports
// real record counts. Cold-start status is therefore unobservable over HTTP —
// smoke tests must poll until the port accepts connections.
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { extname, join, normalize, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Collector } from './collector.js'
import { handleApi } from './api.js'
import { loadFileConfig, ConfigError, type FileConfig } from './config.js'
import { QuotaPoller } from './quotas/poller.js'
import { createQuotaFetch } from './quotas/proxy.js'

const ROOT = fileURLToPath(new URL('../..', import.meta.url)) // 仓库根

// Optional file defaults (agg.config.json); env vars override the file.
// AGG_CONFIG 重定向配置文件（菜单栏客户端打包态用），默认仓库根 agg.config.json。
// 坏配置直接退出（exit 1）：带着错误端口/刷新间隔启动比拒绝启动更难排查。
const CONFIG_FILE = process.env['AGG_CONFIG'] ?? join(ROOT, 'agg.config.json')
let fileConfig: FileConfig
try {
  fileConfig = await loadFileConfig(CONFIG_FILE)
} catch (err) {
  console.error(`[agg-server] ${err instanceof ConfigError ? err.message : String(err)}`)
  process.exit(1)
}
// 实例身份：客户端（App）接管外部实例前核对配置来源用；进程生命周期内稳定
const INSTANCE_ID = randomUUID()

// env 数值解析：未设置与显式空串都视为「未覆盖」；设置但非法 → 带说明退出，
// 不再 Number() 后静默产出 NaN/0 之类的意外值。
function envNumber(name: string, fallback: number, min: number, max: number, integer = false): number {
  const raw = process.env[name]
  if (raw === undefined || raw === '') return fallback
  const n = Number(raw)
  if (!Number.isFinite(n) || n < min || n > max || (integer && !Number.isInteger(n))) {
    console.error(`[agg-server] 环境变量 ${name}="${raw}" 不合法（需 ${min}–${max}${integer ? ' 的整数' : ''}）`)
    process.exit(1)
  }
  return n
}

const webDistEnv = process.env['CODEBURN_AGG_WEB']
const WEB_DIST = resolve(webDistEnv && webDistEnv.trim() ? webDistEnv : fileConfig.webDist ?? join(ROOT, 'web', 'dist'))
const PORT = envNumber('CODEBURN_AGG_PORT', fileConfig.port ?? 8317, 1, 65535, true)
const REFRESH_MINUTES = envNumber('CODEBURN_AGG_REFRESH_MIN', fileConfig.refreshMinutes ?? 30, 1, 24 * 60)

const collector = new Collector()
// 订阅账号额度（GLM/Codex/Claude/Cursor/WorkBuddy/Trae）：受限网络域名走
// 系统代理（undici ProxyAgent，运行时生效），后台低频轮询（QuotaPoller 内部
// TTL 5 分钟）；单 provider 失败不影响其它与主看板
const { fetchLike: quotaFetch, proxyUrl } = await createQuotaFetch()
if (proxyUrl) console.log(`[agg-server] 额度出网代理：${proxyUrl}`)
const quotaPoller = new QuotaPoller({ fetchImpl: quotaFetch })
void quotaPoller.current().catch(() => undefined)
setInterval(() => void quotaPoller.current().catch(() => undefined), 60 * 1000)
let refreshing = false
let pendingRefresh = false
async function refreshOnce(): Promise<void> {
  // 并发/排队语义：采集进行中再收到刷新请求（如镜像完成触发的补采）不丢弃，
  // 记一个待办，本轮结束后立刻补跑一次，保证最新数据不被吞。
  if (refreshing) { pendingRefresh = true; return }
  refreshing = true
  try {
    await collector.refresh()
    while (pendingRefresh) {
      pendingRefresh = false
      await collector.refresh()
    }
  } catch (err) {
    // refresh() itself never rejects (all errors land in snapshot.errors); this
    // is belt-and-braces so a bug there can never take the server down via an
    // unhandled rejection.
    console.error('[agg-server] refresh failed:', err)
  } finally { refreshing = false }
}

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json',
  '.ico': 'image/x-icon', '.txt': 'text/plain; charset=utf-8', '.map': 'application/json',
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://127.0.0.1')
  try {
    // DNS-rebinding / cross-site hardening for /api/*:
    // - Host must be exactly the bound loopback host:port. A rebinding attacker
    //   can make the browser send requests with an attacker-chosen Host (or
    //   attackerOrigin:port), which fails this check → 403. Exact equality (not
    //   startsWith) so a lookalike port like 127.0.0.1:83170 can't slip through
    //   a `127.0.0.1:8317` prefix rule.
    // - POST /api/refresh (the only state-changing endpoint) additionally rejects
    //   a cross-origin Origin header when present (form-post CSRF from another
    //   origin always carries Origin; simple GETs may omit it).
    // There is no HTTP-layer test harness in server/tests (node:test suites only
    // cover pure modules); this guard is verified by curl:
    //   curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: evil.com' \
    //     http://127.0.0.1:8317/api/refresh          → 403
    //   curl -s -o /dev/null -w '%{http_code}' -X POST \
    //     http://127.0.0.1:8317/api/refresh          → 202
    if (url.pathname.startsWith('/api/')) {
      if (req.headers.host !== `127.0.0.1:${PORT}`) { res.writeHead(403).end(); return }
      const origin = req.headers.origin
      if (req.method === 'POST' && typeof origin === 'string'
        && !origin.startsWith(`http://127.0.0.1:${PORT}`)) {
        res.writeHead(403).end(); return
      }
    }
    if (url.pathname === '/api/refresh' && req.method === 'POST') {
      void refreshOnce()
      res.writeHead(202, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ ok: true })); return
    }
    if (url.pathname.startsWith('/api/')) {
      const { status, body } = handleApi(url, collector.snapshot, collector.localHost, {
        instanceId: INSTANCE_ID, configPath: CONFIG_FILE, port: PORT,
      }, quotaPoller.snapshot)
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(JSON.stringify(body)); return
    }
    // Static files. WHATWG URL parsing already collapses `.`/`..` segments
    // (including the %2e-encoded forms) before we ever see url.pathname; the
    // resolve() + separator-aware prefix check below backstops anything that
    // could slip through. resolve() is required: a plain join() + startsWith()
    // would admit lookalike siblings (WEB_DIST/../..-style escapes survive
    // join verbatim) and prefix matches like WEB_DIST-evil.
    const rel = url.pathname === '/' ? 'index.html' : normalize(url.pathname).replace(/^([/\\])+/, '')
    const file = resolve(join(WEB_DIST, rel))
    if (file !== WEB_DIST && !file.startsWith(WEB_DIST + sep)) { res.writeHead(403).end(); return }
    const data = await readFile(file)
    res.writeHead(200, { 'content-type': MIME[extname(file)] ?? 'application/octet-stream' })
    res.end(data)
  } catch {
    // Missing web/dist (pre-Task-8), bad paths, directories — all 404 gracefully.
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }); res.end('not found')
  }
})

await refreshOnce()
setInterval(() => void refreshOnce(), REFRESH_MINUTES * 60 * 1000)
server.listen(PORT, '127.0.0.1', () => {
  console.log(`[agg-server] http://127.0.0.1:${PORT}  records=${collector.snapshot.rows.length}  localHost=${collector.localHost}  refresh=${REFRESH_MINUTES}min  web=${WEB_DIST}`)
})
