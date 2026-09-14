// server/src/quotas/codebuff.ts — Codebuff 订阅额度（移植 CodexBar CodebuffUsageFetcher）：
// 凭据 = env CODEBUFF_API_KEY 或 ~/.config/manicode/credentials.json（codebuff login 写入）；
// POST {base}/api/v1/usage（注意是 POST）+ 可选 GET {base}/api/user/subscription。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, toEpochMs, percentOf,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export type CodebuffAuth = { token: string; baseUrl: string }

export function readCodebuffAuth(home: string, env: NodeJS.ProcessEnv): CodebuffAuth | null {
  const envToken = env['CODEBUFF_API_KEY']
  const baseUrl = (env['CODEBUFF_API_URL']?.trim() || 'https://www.codebuff.com').replace(/\/+$/, '')
  if (envToken && envToken.trim()) return { token: envToken.trim(), baseUrl }
  let raw: string
  try {
    raw = readFileSync(join(home, '.config', 'manicode', 'credentials.json'), 'utf8')
  } catch {
    return null
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch { return null }
  const root = parsed as Record<string, any>
  const token = quotaStr(root['authToken']) ?? quotaStr(root['default']?.['authToken'])
  return token ? { token, baseUrl } : null
}

export async function fetchCodebuffAccount(
  auth: CodebuffAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${auth.token}`,
    accept: 'application/json',
    'content-type': 'application/json',
  }
  try {
    const usage = await quotaFetchJson(doFetch, `${auth.baseUrl}/api/v1/usage`, {
      method: 'POST', headers, body: JSON.stringify({ fingerprintId: 'wattson-usage' }),
    })
    const u = (usage.body ?? {}) as Record<string, any>
    const used = quotaNum(u['usage']) ?? quotaNum(u['used'])
    const total = quotaNum(u['quota']) ?? quotaNum(u['limit'])
    const remaining = quotaNum(u['remainingBalance']) ?? quotaNum(u['remaining'])
    const nextQuotaReset = toEpochMs(u['next_quota_reset'])

    const windows: QuotaWindow[] = []
    if (used !== null || total !== null || remaining !== null) {
      windows.push({
        key: 'credits', label: '积分额度',
        total, used, remaining,
        percentage: percentOf(used ?? (total !== null && remaining !== null ? total - remaining : null), total),
        nextResetAt: nextQuotaReset,
      })
    }

    // 订阅与周窗口是可选增强（CodexBar 给 2s grace），失败不拖垮主快照
    let planName: string | null = null
    try {
      const sub = await quotaFetchJson(doFetch, `${auth.baseUrl}/api/user/subscription`, { headers, timeoutMs: 5_000 })
      const s = (sub.body ?? {}) as Record<string, any>
      const subscription = (s['subscription'] ?? null) as Record<string, any> | null
      const rateLimit = (s['rateLimit'] ?? null) as Record<string, any> | null
      planName = quotaStr(subscription?.['displayName']) ?? quotaStr(s['displayName'])
        ?? quotaStr(subscription?.['tier']) ?? quotaStr(s['tier'])
      const weeklyUsed = quotaNum(rateLimit?.['weeklyUsed']) ?? quotaNum(rateLimit?.['used'])
      const weeklyLimit = quotaNum(rateLimit?.['weeklyLimit']) ?? quotaNum(rateLimit?.['limit'])
      if (weeklyUsed !== null || weeklyLimit !== null) {
        windows.push({
          key: 'week', label: '周额度',
          total: weeklyLimit, used: weeklyUsed, remaining: null,
          percentage: percentOf(weeklyUsed, weeklyLimit),
          nextResetAt: toEpochMs(rateLimit?.['weeklyResetsAt']),
        })
      }
    } catch {
      // 订阅端点不可得时仅展示积分窗口
    }

    return finalizeAccount({
      kind: 'codebuff', label: 'Codebuff', provider: null,
      planName, windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'codebuff', label: 'Codebuff', provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function codebuffAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readCodebuffAuth(home, env)
  if (!auth) return missingAccount('codebuff', 'Codebuff', now)
  return fetchCodebuffAccount(auth, doFetch, now)
}
