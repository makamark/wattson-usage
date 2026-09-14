// server/src/quotas/kimi.ts — Kimi 订阅额度（移植 CodexBar KimiUsageFetcher 的 Code API 口径）：
// 凭据 = env KIMI_CODE_API_KEY 或 ~/.kimi-code/credentials/kimi-code.json（须未过期）；
// GET {base}/coding/v1/usages，头 Bearer + X-Msh-Platform: kimi_code_cli；
// usage.detail = 周额度（绝对值），limits[0].detail = 速率窗口。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, toEpochMs, percentOf,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export type KimiAuth = { token: string; baseUrl: string }

/** Kimi 会员档位 → 展示名（对齐 CodexBar KimiCodeAPIUsageResponse.User.Membership） */
export function kimiPlanName(level: string | null): string | null {
  switch (level?.trim().toUpperCase()) {
    case 'LEVEL_FREE': return 'Adagio'
    case 'LEVEL_TRIAL': return 'Andante'
    case 'LEVEL_BASIC': return 'Moderato'
    case 'LEVEL_INTERMEDIATE': return 'Allegretto'
    case 'LEVEL_ADVANCED': return 'Allegro'
    default: return level?.trim() || null
  }
}

/** 凭据：env KIMI_CODE_API_KEY 优先；其次 ~/.kimi-code/credentials/kimi-code.json（expires_at 须 > now+60s） */
export function readKimiAuth(home: string, env: NodeJS.ProcessEnv, now = Date.now()): KimiAuth | null {
  const baseUrl = (env['KIMI_CODE_BASE_URL']?.trim() || 'https://api.kimi.com').replace(/\/+$/, '')
  const envToken = env['KIMI_CODE_API_KEY']
  if (envToken && envToken.trim()) return { token: envToken.trim(), baseUrl }
  const codeHome = env['KIMI_CODE_HOME']?.trim() || join(home, '.kimi-code')
  let raw: string
  try {
    raw = readFileSync(join(codeHome, 'credentials', 'kimi-code.json'), 'utf8')
  } catch {
    return null
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch { return null }
  const root = parsed as Record<string, any>
  const token = quotaStr(root['access_token'])
  if (!token) return null
  const expiresAt = quotaNum(root['expires_at'])
  if (expiresAt === null || expiresAt <= now / 1000 + 60) return null
  return { token, baseUrl }
}

/** detail 结构：limit/used/remaining 可能是字符串数字；resetTime 兼容 reset_time/reset_at 蛇形 */
function windowFromDetail(
  key: string, label: string, raw: unknown,
): QuotaWindow | null {
  if (raw === null || typeof raw !== 'object') return null
  const d = raw as Record<string, unknown>
  const total = quotaNum(d['limit'])
  const used = quotaNum(d['used'])
  const remaining = quotaNum(d['remaining'])
  const percentage = percentOf(used, total)
  const resetAt = toEpochMs(d['resetTime'] ?? d['reset_time'] ?? d['reset_at'])
  if (percentage === null && resetAt === null) return null
  return { key, label, total, used, remaining, percentage, nextResetAt: resetAt }
}

export async function fetchKimiAccount(
  auth: KimiAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${auth.token}`,
    accept: 'application/json',
    'x-msh-platform': 'kimi_code_cli',
    'user-agent': 'wattson-usage',
  }
  try {
    const { body } = await quotaFetchJson(
      doFetch, `${auth.baseUrl}/coding/v1/usages`, { headers },
    )
    const root = (body ?? {}) as Record<string, any>
    const usage = (root['usage'] ?? null) as Record<string, unknown> | null
    const limits = Array.isArray(root['limits']) ? root['limits'] : []
    const rateLimit = (limits[0] ?? null) as Record<string, any> | null
    const membership = (root['user']?.membership ?? null) as Record<string, any> | null
    const windows: QuotaWindow[] = []
    const week = windowFromDetail('week', '周额度', usage)
    if (week) windows.push(week)
    const rate = rateLimit ? windowFromDetail('rate', '速率限制', rateLimit['detail']) : null
    if (rate) windows.push(rate)
    return finalizeAccount({
      kind: 'kimi', label: 'Kimi', provider: null,
      planName: kimiPlanName(quotaStr(membership?.['level'])),
      windows, anySuccess: usage !== null, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'kimi', label: 'Kimi', provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function kimiAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readKimiAuth(home, env, now)
  if (!auth) return missingAccount('kimi', 'Kimi', now)
  return fetchKimiAccount(auth, doFetch, now)
}
