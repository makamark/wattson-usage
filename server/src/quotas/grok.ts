// server/src/quotas/grok.ts — Grok CLI 订阅额度（移植 CodexBar GrokCreditsProxyFetcher）：
// 凭据 = env GROK_OAUTH_TOKEN 或 ~/.grok/auth.json（scope 键控映射，优先 SuperGrok OIDC）；
// GET https://cli-chat-proxy.grok.com/v1/billing?format=credits，
// 头 Bearer + x-xai-token-auth: xai-grok-cli；config.creditUsagePercent = 已用百分比。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, toEpochMs, percentOf, toPercent,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export type GrokAuth = { token: string; expired: boolean }

/** SuperGrok / SuperGrok Heavy 档位名归一（对齐 CodexBar GrokPlan.displayName） */
export function grokPlanName(raw: string | null): string | null {
  const trimmed = raw?.trim() ?? ''
  if (!trimmed) return null
  const compact = trimmed.toLowerCase().replace(/[^a-z]/g, '')
  if (compact === 'supergrokheavy' || compact === 'heavy') return 'SuperGrok Heavy'
  if (compact === 'supergrok') return 'SuperGrok'
  return trimmed
}

const OIDC_SCOPE_PREFIX = 'https://auth.x.ai::'
const LEGACY_SESSION_SCOPE = 'https://accounts.x.ai/sign-in'

/** 凭据：env GROK_OAUTH_TOKEN 优先；其次 ~/.grok/auth.json（GROK_HOME 可覆盖）。
 * auth.json 是 scope → entry 映射，只接受带非空 key 的条目；优先 OIDC，回退 legacy session。 */
export function readGrokAuth(home: string, env: NodeJS.ProcessEnv, now = Date.now()): GrokAuth | null {
  const envToken = env['GROK_OAUTH_TOKEN']
  if (envToken && envToken.trim()) return { token: envToken.trim(), expired: false }
  const grokHome = env['GROK_HOME']?.trim() || join(home, '.grok')
  let raw: string
  try {
    raw = readFileSync(join(grokHome, 'auth.json'), 'utf8')
  } catch {
    return null
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch { return null }
  if (parsed === null || typeof parsed !== 'object') return null
  let oidc: { token: string; expiresAt: number | null } | null = null
  let legacy: { token: string; expiresAt: number | null } | null = null
  for (const [scope, value] of Object.entries(parsed as Record<string, unknown>)) {
    if (value === null || typeof value !== 'object') continue
    const entry = value as Record<string, unknown>
    const token = quotaStr(entry['key'])
    if (!token) continue
    const candidate = { token, expiresAt: toEpochMs(entry['expires_at']) }
    if (scope.startsWith(OIDC_SCOPE_PREFIX)) oidc = candidate
    else if (scope === LEGACY_SESSION_SCOPE || scope.includes('/sign-in')) legacy ??= candidate
  }
  const picked = oidc ?? legacy
  if (!picked) return null
  const expired = picked.expiresAt !== null && picked.expiresAt <= now
  return { token: picked.token, expired }
}

export async function fetchGrokAccount(
  auth: GrokAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${auth.token}`,
    'x-xai-token-auth': 'xai-grok-cli',
    accept: 'application/json',
    'user-agent': 'wattson-usage',
  }
  try {
    const { body } = await quotaFetchJson(
      doFetch, 'https://cli-chat-proxy.grok.com/v1/billing?format=credits', { headers },
    )
    const root = (body ?? {}) as Record<string, any>
    const config = (root['config'] ?? null) as Record<string, any> | null
    if (!config) throw new Error('响应缺少 config 字段')
    const resetAt = toEpochMs(config['currentPeriod']?.['end'] ?? config['billingPeriodEnd'])
    // 优先 creditUsagePercent；否则 onDemandCap/onDemandUsed（{val: number}）推导
    const usedPercent = toPercent(quotaNum(config['creditUsagePercent']))
      ?? percentOf(
        quotaNum(config['onDemandUsed']?.['val']),
        quotaNum(config['onDemandCap']?.['val']),
      )
    const windows: QuotaWindow[] = []
    if (usedPercent !== null || resetAt !== null) {
      windows.push({ key: 'cycle', label: '订阅额度', usedPercent, percentage: usedPercent, nextResetAt: resetAt })
    }
    return finalizeAccount({
      kind: 'grok', label: 'Grok', provider: null,
      planName: grokPlanName(quotaStr(config['subscriptionTier']) ?? quotaStr(root['subscriptionTier'])),
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'grok', label: 'Grok', provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function grokAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readGrokAuth(home, env, now)
  if (!auth) return missingAccount('grok', 'Grok', now)
  if (auth.expired) {
    return {
      kind: 'grok', label: 'Grok', available: false, unavailableReason: 'error',
      error: '凭据已过期，请重新 grok login', planName: null, windows: [],
      fetchedAt: now, lastSuccessAt: null,
    }
  }
  return fetchGrokAccount(auth, doFetch, now)
}
