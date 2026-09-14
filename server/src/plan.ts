// server/src/plan.ts — 订阅账号（GLM Coding Plan / ZCode）用量额度。
// 参考 cockpit-tools 的 ZCode 集成与 ZCode 桌面端自身实现，走官方接口：
//   GET {host}/api/biz/subscription/list       → 套餐订阅明细（productName/billingCycle/有效期）
//   GET {host}/api/monitor/usage/quota/limit   → 额度窗口 data.limits[]（5 小时窗口/周）+ data.level
// 认证 = ~/.zcode/v2/credentials.json 中 coding-plan 账号的 api-key（zcode CLI 的
// `enc:v1:` AES-256-GCM 方案加密，密钥 = SHA256("zcode-credential-fallback:{platform}:{home}:{user}")，
// 可被 ZCODE_CREDENTIAL_SECRET 覆盖）；或直接用 BIGMODEL_USAGE_API_KEY / ZCODE_BIGMODEL_USAGE_API_KEY。
// 凭据只留在服务端内存：/api/plan 只回传额度数据，绝不回传 key/JWT。
import { createHash, createDecipheriv } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { platform as osPlatform, userInfo } from 'node:os'
import { join } from 'node:path'

export type PlanWindow = {
  /** fiveHour | week | unit-<n> */
  key: string
  /** 展示名（如「5 小时窗口」「周」） */
  label: string
  /** 总额度（usage 字段，prompt/credit 数） */
  total: number
  /** 已用（currentValue） */
  used: number
  remaining: number
  /** 官方百分比（0-100），缺失为 null */
  percentage: number | null
  /** 本窗口重置时间（ms epoch），缺失为 null */
  nextResetAt: number | null
}

export type PlanSnapshot = {
  available: boolean
  /** no_credentials | loading | http_401 | http_error | no_plan | error */
  unavailableReason: string | null
  error: string | null
  /** coding-plan providerId（如 bigmodel-individual-coding-plan） */
  provider: string | null
  planName: string | null
  level: string | null
  billingCycle: string | null
  validFrom: string | null
  validTo: string | null
  autoRenew: boolean | null
  windows: PlanWindow[]
  fetchedAt: number
  lastSuccessAt: number | null
}

export const PLAN_TTL_MS = 5 * 60 * 1000
const FETCH_TIMEOUT_MS = 15 * 1000

// ---------- 凭据解密（与 zcode CLI / cockpit-tools 同方案的只读复刻） ----------

export function credentialSecret(home: string, platform: string, user: string, env: NodeJS.ProcessEnv): string {
  const fromEnv = env['ZCODE_CREDENTIAL_SECRET']
  if (fromEnv) return fromEnv
  return `zcode-credential-fallback:${platform}:${home}:${user}`
}

export function decryptCredential(value: string, secret: string): string | null {
  const PREFIX = 'enc:v1:'
  if (!value.startsWith(PREFIX)) return value
  const parts = value.slice(PREFIX.length).split('.')
  if (parts.length !== 3) return null
  try {
    const nonce = Buffer.from(parts[0]!, 'base64url')
    const tag = Buffer.from(parts[1]!, 'base64url')
    const data = Buffer.from(parts[2]!, 'base64url')
    if (nonce.length !== 12 || tag.length !== 16) return null
    const key = createHash('sha256').update(secret).digest()
    const decipher = createDecipheriv('aes-256-gcm', key, nonce)
    decipher.setAuthTag(tag)
    return Buffer.concat([decipher.update(data), decipher.final()]).toString('utf8')
  } catch {
    return null
  }
}

/** zcode 的 api-key 头归一化：剥 Bearer、取 id.secret 形态（口径同 ZCode 桌面端） */
export function normalizeApiKey(raw: string): string | null {
  const stripped = raw.trim().replace(/^Bearer\s+/i, '').trim()
  const m = stripped.match(/[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/)
  return m ? m[0] : stripped || null
}

export type CodingPlanAuth = { authorization: string; host: string; provider: string }

/** 解析本机 zcode 凭据里的 coding-plan api-key；env 显式提供时优先（与桌面端口径一致） */
export function readCodingPlanAuth(home: string, env: NodeJS.ProcessEnv): CodingPlanAuth | null {
  const envKey = env['ZCODE_BIGMODEL_USAGE_API_KEY'] ?? env['BIGMODEL_USAGE_API_KEY']
  if (envKey && envKey.trim()) {
    const key = normalizeApiKey(envKey)
    if (key) return { authorization: key, host: 'https://bigmodel.cn', provider: 'env:bigmodel-usage' }
  }
  const secret = credentialSecret(home, osPlatform(), userInfo().username, env)
  const v2Dir = resolveV2Dir(home)
  let raw: string
  try {
    raw = readFileSync(join(v2Dir, 'credentials.json'), 'utf8')
  } catch {
    return null
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch { return null }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null
  const entries = Object.entries(parsed as Record<string, unknown>)
  const candidates: Array<{ provider: string; host: string; key: string | null }> = []
  for (const [name, value] of entries) {
    // 键形如 account-provider:coding-plan:account:<providerId>:account:<customerId>:api-key
    const m = /^account-provider:coding-plan:account:([^:]+):account:[^:]+:api-key$/.exec(name)
    if (!m || typeof value !== 'string') continue
    const provider = m[1]!
    const host = provider.startsWith('zai') ? 'https://zcode.z.ai' : 'https://bigmodel.cn'
    const decrypted = decryptCredential(value, secret)
    const key = decrypted ? normalizeApiKey(decrypted) : null
    candidates.push({ provider, host, key })
  }
  const preferred =
    candidates.find(c => c.key && c.provider.includes('individual-coding-plan')) ??
    candidates.find(c => c.key)
  if (!preferred?.key) return null
  return { authorization: preferred.key, host: preferred.host, provider: preferred.provider }
}

function resolveV2Dir(home: string): string {
  // setting.json 的 dataBaseDir 可重定向 zcode 数据目录（口径同 cockpit-tools resolve_default_v2_dir）
  try {
    const setting = JSON.parse(readFileSync(join(home, '.zcode/v2/setting.json'), 'utf8')) as { dataBaseDir?: unknown }
    if (typeof setting.dataBaseDir === 'string' && setting.dataBaseDir.trim()) {
      return join(setting.dataBaseDir.trim(), '.zcode/v2')
    }
  } catch { /* 无重定向/坏文件 → 默认路径 */ }
  return join(home, '.zcode/v2')
}

// ---------- 响应归一化（纯函数，测试用 fixtures 驱动） ----------

type Envelope = { code?: unknown; msg?: unknown; success?: unknown; data?: unknown }
const isOkEnvelope = (e: Envelope): boolean =>
  e.success !== false && (e.code === undefined || e.code === 0 || e.code === 200)
const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null)
const str = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v.trim() : null)

/** unit 枚举（实测：3=小时、6=周）→ 展示名；未知 unit 给出可读兜底 */
export function windowLabel(unit: number | null, count: number | null): { key: string; label: string } {
  if (unit === 3) return { key: 'fiveHour', label: `${count ?? 5} 小时窗口` }
  if (unit === 6) return { key: 'week', label: '周额度' }
  if (unit !== null) return { key: `unit-${unit}`, label: `额度（unit=${unit}${count !== null ? '×' + count : ''}）` }
  return { key: 'window', label: '额度窗口' }
}

export function parsePlanWindows(limits: unknown): PlanWindow[] {
  if (!Array.isArray(limits)) return []
  const out: PlanWindow[] = []
  for (const item of limits) {
    if (item === null || typeof item !== 'object') continue
    const l = item as Record<string, unknown>
    const total = num(l['usage'])
    const used = num(l['currentValue'])
    if (total === null && used === null) continue
    const { key, label } = windowLabel(num(l['unit']), num(l['number']))
    out.push({
      key, label,
      total: total ?? 0,
      used: used ?? 0,
      remaining: num(l['remaining']) ?? Math.max(0, (total ?? 0) - (used ?? 0)),
      percentage: num(l['percentage']),
      nextResetAt: num(l['nextResetTime']),
    })
  }
  // 5 小时窗口在前、周在后；其余按 key 稳定排序
  const order = (k: string): number => (k === 'fiveHour' ? 0 : k === 'week' ? 1 : 2)
  return out.sort((a, b) => order(a.key) - order(b.key))
}

export type PlanSubscription = {
  planName: string | null; billingCycle: string | null
  validFrom: string | null; validTo: string | null
  autoRenew: boolean | null; nextRenewAt: string | null
}

export function parseSubscription(list: unknown): PlanSubscription {
  const empty: PlanSubscription = { planName: null, billingCycle: null, validFrom: null, validTo: null, autoRenew: null, nextRenewAt: null }
  const data = (list as Envelope | undefined)?.data
  if (!Array.isArray(data)) return empty
  // 口径同桌面端：优先当前周期且 VALID，其次任一 VALID/当前周期
  const pick =
    data.find((s): s is Record<string, unknown> =>
      s !== null && typeof s === 'object' && (s as Record<string, unknown>)['inCurrentPeriod'] === true && (s as Record<string, unknown>)['status'] === 'VALID') ??
    data.find((s): s is Record<string, unknown> => s !== null && typeof s === 'object' && (s as Record<string, unknown>)['inCurrentPeriod'] === true) ??
    data.find((s): s is Record<string, unknown> => s !== null && typeof s === 'object' && (s as Record<string, unknown>)['status'] === 'VALID')
  if (!pick) return empty
  const valid = str(pick['valid'])
  // valid 形如 "2026-12-09 10:00:00-2027-03-09 10:00:00"
  const range = valid ? /^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})-(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})$/.exec(valid) : null
  const autoRaw = pick['autoRenew']
  return {
    planName: str(pick['productName']),
    billingCycle: str(pick['billingCycle']),
    validFrom: range ? range[1]! : null,
    validTo: range ? range[2]! : null,
    autoRenew: typeof autoRaw === 'boolean' ? autoRaw : autoRaw === 1 ? true : autoRaw === 0 ? false : null,
    nextRenewAt: str(pick['nextRenewTime']),
  }
}

// ---------- 拉取与轮询 ----------
// 轮询编排已升级为多 provider 的 QuotaPoller（见 quotas/poller.ts）；
// 本文件保留 GLM Coding Plan 单源的凭据解析与拉取实现，供 QuotaPoller 复用。

type FetchLike = (url: string, init: { signal: AbortSignal; headers: Record<string, string> }) => Promise<{ ok: boolean; status: number; json: () => Promise<unknown> }>

export async function fetchPlanSnapshot(
  auth: CodingPlanAuth,
  doFetch: FetchLike,
  now: number,
): Promise<PlanSnapshot> {
  const snapshot: PlanSnapshot = {
    available: false, unavailableReason: null, error: null,
    provider: auth.provider, planName: null, level: null, billingCycle: null,
    validFrom: null, validTo: null, autoRenew: null,
    windows: [], fetchedAt: now, lastSuccessAt: null,
  }
  const getJson = async (url: string): Promise<Envelope> => {
    const ac = new AbortController()
    const timer = setTimeout(() => ac.abort(), FETCH_TIMEOUT_MS)
    try {
      const res = await doFetch(url, { signal: ac.signal, headers: { authorization: auth.authorization } })
      if (res.status === 401 || res.status === 403) throw Object.assign(new Error(`HTTP ${res.status}（凭据无效或已过期）`), { planHttpStatus: res.status })
      if (!res.ok) throw Object.assign(new Error(`HTTP ${res.status}`), { planHttpStatus: res.status })
      return await res.json() as Envelope
    } finally {
      clearTimeout(timer)
    }
  }
  const [sub, quota] = await Promise.allSettled([
    getJson(`${auth.host}/api/biz/subscription/list`),
    getJson(`${auth.host}/api/monitor/usage/quota/limit`),
  ])
  let httpStatus: number | null = null
  const readStatus = (err: unknown): number | null =>
    (err as { planHttpStatus?: number } | null)?.planHttpStatus ?? null
  let error: string | null = null
  let successCount = 0
  if (sub.status === 'fulfilled') {
    if (isOkEnvelope(sub.value)) { successCount += 1; Object.assign(snapshot, parseSubscription(sub.value)) }
    else error = str(sub.value['msg']) ?? '订阅接口返回失败'
  } else {
    httpStatus = readStatus(sub.reason) ?? httpStatus
    error = sub.reason instanceof Error ? sub.reason.message : String(sub.reason)
  }
  if (quota.status === 'fulfilled') {
    const q = quota.value
    if (isOkEnvelope(q)) {
      successCount += 1
      const data = (q.data ?? {}) as Record<string, unknown>
      snapshot.level = str(data['level'])
      snapshot.windows = parsePlanWindows(data['limits'])
      if (!snapshot.windows.length && !error) error = str(q['msg']) ?? '额度接口未返回窗口数据'
    } else if (!error) error = str(q['msg']) ?? '额度接口返回失败'
  } else {
    httpStatus = readStatus(quota.reason) ?? httpStatus
    if (!error) error = quota.reason instanceof Error ? quota.reason.message : String(quota.reason)
  }
  snapshot.error = error
  if (successCount > 0) {
    snapshot.available = snapshot.windows.length > 0 || snapshot.planName !== null
    if (snapshot.available) snapshot.lastSuccessAt = now
    else snapshot.unavailableReason = 'no_plan'
  } else {
    snapshot.unavailableReason = httpStatus === 401 || httpStatus === 403 ? 'http_401' : httpStatus !== null ? 'http_error' : 'error'
  }
  return snapshot
}

/** Node 18+ 原生 fetch 注上一层，匹配 FetchLike 形状 */
const defaultFetch: (url: string, init: { signal: AbortSignal; headers: Record<string, string> }) => Promise<{ ok: boolean; status: number; json: () => Promise<unknown> }> =
  (url, init) => fetch(url, init)
