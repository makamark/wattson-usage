// server/src/quotas/openrouter.ts — OpenRouter 额度（移植 CodexBar openrouter.js 插件口径）：
// 凭据 = env OPENROUTER_API_KEY；GET {base}/credits → data.total_credits/total_usage；
// 可选 GET {base}/key → 限额窗口（limit/limit_remaining/usage + limit_reset）。
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, percentOf,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

const LABEL = 'OpenRouter'

export function readOpenRouterAuth(env: NodeJS.ProcessEnv): { token: string; baseUrl: string } | null {
  const token = env['OPENROUTER_API_KEY']
  if (!token || !token.trim()) return null
  const baseUrl = (env['OPENROUTER_API_URL']?.trim() || 'https://openrouter.ai/api/v1').replace(/\/+$/, '')
  return { token: token.trim(), baseUrl }
}

export async function fetchOpenRouterAccount(
  auth: { token: string; baseUrl: string }, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${auth.token}`,
    'x-title': 'wattson-usage',
  }
  try {
    const credits = await quotaFetchJson(doFetch, `${auth.baseUrl}/credits`, { headers })
    const creditsData = ((credits.body ?? {}) as Record<string, any>)['data'] ?? {}
    const totalCredits = quotaNum(creditsData['total_credits'])
    const totalUsage = quotaNum(creditsData['total_usage'])
    if (totalCredits === null || totalUsage === null) throw new Error('credits 响应缺少 total_credits/total_usage')
    const balance = Math.max(0, totalCredits - totalUsage)

    const windows: QuotaWindow[] = [{
      key: 'credits', label: '账户余额',
      total: totalCredits, used: totalUsage, remaining: balance,
      percentage: percentOf(totalUsage, totalCredits),
      nextResetAt: null,
    }]

    // /key 是可选增强：失败不拖垮主快照
    try {
      const key = await quotaFetchJson(doFetch, `${auth.baseUrl}/key`, { headers, timeoutMs: 5_000 })
      const keyData = ((key.body ?? {}) as Record<string, any>)['data'] ?? {}
      const limit = quotaNum(keyData['limit'])
      if (limit !== null && limit > 0) {
        const limitRemaining = quotaNum(keyData['limit_remaining'])
        const keyUsed = limitRemaining !== null
          ? Math.min(limit, Math.max(0, limit - limitRemaining))
          : Math.min(limit, quotaNum(keyData['usage']) ?? 0)
        windows.push({
          key: 'limit', label: 'Key 限额',
          total: limit, used: keyUsed, remaining: Math.max(0, limit - keyUsed),
          percentage: percentOf(keyUsed, limit),
          nextResetAt: null,
        })
      }
    } catch {
      // key 限额不可得时仅展示余额窗口
    }

    return finalizeAccount({
      kind: 'openrouter', label: LABEL, provider: null,
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'openrouter', label: LABEL, provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function openrouterAccount(_home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readOpenRouterAuth(env)
  if (!auth) return missingAccount('openrouter', LABEL, now)
  return fetchOpenRouterAccount(auth, doFetch, now)
}
