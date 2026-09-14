// server/src/quotas/types.ts — 订阅额度多 provider 共享类型与工具。
// 统一窗口模型兼容两种口径：绝对值（glm/workbuddy 的 总额/已用/剩余）与
// 纯百分比（codex/claude/cursor 只给 used_percent/utilization）。

export type QuotaKind =
  | 'glm' | 'codex' | 'claude' | 'cursor' | 'workbuddy' | 'trae'
  | 'kimi' | 'gemini' | 'grok' | 'zed' | 'kiro' | 'codebuff' | 'factory'
  | 'copilot' | 'openrouter' | 'minimax'

export type QuotaWindow = {
  /** fiveHour | week | cycle | sevenDaySonnet | extra | … */
  key: string
  label: string
  /** 已用百分比（0-100）。纯百分比口径的 provider 只填这个 */
  usedPercent?: number | null
  /** 绝对值口径（prompt/credit 数），缺失为 null */
  total?: number | null
  used?: number | null
  remaining?: number | null
  /** 展示百分比 0-100：优先官方值，否则由 used/total 推导；都没有则取 usedPercent */
  percentage: number | null
  nextResetAt: number | null
}

export type QuotaAccount = {
  kind: QuotaKind
  label: string
  available: boolean
  /** no_credentials | loading | http_401 | http_error | no_plan | error | uninitialized */
  unavailableReason: string | null
  error: string | null
  planName: string | null
  windows: QuotaWindow[]
  /** 额度重置卡张数（codex rate_limit_reset_credits.available_count）；无此概念不设 */
  resetCredits?: number | null
  /** 当前额度状态下可用的重置卡张数（applicable_available_count）；无此概念不设 */
  applicableResetCredits?: number | null
  fetchedAt: number
  lastSuccessAt: number | null
}

export type QuotaSnapshot = { accounts: QuotaAccount[] }

export type FetchLike = (url: string, init: {
  method?: string
  signal?: AbortSignal
  headers?: Record<string, string>
  body?: string
}) => Promise<{ ok: boolean; status: number; json: () => Promise<unknown> }>

export const quotaNum = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? v
    : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v)) ? Number(v) : null

export const quotaStr = (v: unknown): string | null =>
  typeof v === 'string' && v.trim() ? v.trim() : null

/** utilization 兼容 0-1 与 0-100 两种口径，统一成 0-100 */
export function toPercent(v: number | null): number | null {
  if (v === null) return null
  return v > 0 && v <= 1 ? v * 100 : v
}

/** 由 used/total 推导百分比（0-100） */
export function percentOf(used: number | null, total: number | null): number | null {
  if (used === null || total === null || total <= 0) return null
  return Math.min(100, Math.max(0, used / total * 100))
}

/** 把 epoch 秒/毫秒或 ISO 字符串归一成 ms；无效为 null */
export function toEpochMs(v: unknown): number | null {
  const n = quotaNum(v)
  if (n !== null) {
    if (n <= 0) return null
    return n < 1e12 ? n * 1000 : n // 秒 → 毫秒
  }
  const s = quotaStr(v)
  if (s) {
    const t = Date.parse(s.includes('T') || s.includes('Z') ? s : s.replace(' ', 'T'))
    if (Number.isFinite(t)) return t
  }
  return null
}

export type AccountInit = {
  kind: QuotaKind
  label: string
  provider: string | null
  planName?: string | null
  windows?: QuotaWindow[]
  error?: string | null
  httpStatus?: number | null
  anySuccess?: boolean
  now: number
  resetCredits?: number | null
  applicableResetCredits?: number | null
}

/** 各 provider 通用的 QuotaAccount 收尾：按成功数/HTTP 状态归一可用性 */
export function finalizeAccount(init: AccountInit): QuotaAccount {
  const available = (init.anySuccess === true) && (init.windows?.length ?? 0) > 0
  let unavailableReason: string | null = available ? null
    : init.httpStatus === 401 || init.httpStatus === 403 ? 'http_401'
      : init.httpStatus !== null && init.httpStatus !== undefined ? 'http_error'
        : init.anySuccess === true ? 'no_plan' : 'error'
  if (!available && unavailableReason === null) unavailableReason = 'error'
  return {
    kind: init.kind,
    label: init.label,
    available,
    unavailableReason,
    error: init.error ?? null,
    planName: init.planName ?? null,
    windows: init.windows ?? [],
    resetCredits: init.resetCredits ?? null,
    applicableResetCredits: init.applicableResetCredits ?? null,
    fetchedAt: init.now,
    lastSuccessAt: available ? init.now : null,
  }
}

/** 无凭据时的占位账号 */
export function missingAccount(kind: QuotaKind, label: string, now: number): QuotaAccount {
  return {
    kind, label, available: false, unavailableReason: 'no_credentials', error: null,
    planName: null, windows: [], fetchedAt: now, lastSuccessAt: null,
  }
}

/** 带超时的 GET/POST（依赖宿主 fetch 已配好代理 env） */
export async function quotaFetchJson(
  doFetch: FetchLike,
  url: string,
  opts: { method?: string; headers: Record<string, string>; body?: string; timeoutMs?: number },
): Promise<{ status: number; body: unknown }> {
  const ac = new AbortController()
  const timer = setTimeout(() => ac.abort(), opts.timeoutMs ?? 15_000)
  try {
    const res = await doFetch(url, {
      method: opts.method ?? 'GET',
      headers: opts.headers,
      body: opts.body,
      signal: ac.signal,
    })
    if (res.status === 401 || res.status === 403) {
      throw Object.assign(new Error(`HTTP ${res.status}（凭据无效或已过期）`), { quotaHttpStatus: res.status })
    }
    if (!res.ok) throw Object.assign(new Error(`HTTP ${res.status}`), { quotaHttpStatus: res.status })
    return { status: res.status, body: await res.json() }
  } finally {
    clearTimeout(timer)
  }
}

export const readHttpStatus = (err: unknown): number | null =>
  (err as { quotaHttpStatus?: number } | null)?.quotaHttpStatus ?? null

export const errText = (err: unknown): string =>
  err instanceof Error ? err.message : String(err)
