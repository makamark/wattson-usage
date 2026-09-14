// server/src/quotas/codex.ts — OpenAI Codex 订阅额度（参考 cockpit-tools codex_quota.rs
// 与 Codex CLI 口径）：GET https://chatgpt.com/backend-api/wham/usage，
// 头 Authorization: Bearer + ChatGPT-Account-Id；primary_window=5 小时、secondary=周。
// chatgpt.com 国内网络不可达：依赖宿主进程配置代理 env（见 quotas/proxy.ts）。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, toEpochMs, toPercent,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export type CodexAuth = { token: string; accountId: string | null }

/** 从 JWT payload 里取 ChatGPT 账户 ID（auth.json 缺 account_id 时的兜底） */
export function extractCodexAccountId(token: string): string | null {
  const parts = token.split('.')
  if (parts.length !== 3) return null
  try {
    const payload = JSON.parse(Buffer.from(parts[1]!, 'base64url').toString('utf8')) as {
      ['https://api.openai.com/auth']?: { chatgpt_account_id?: unknown }
      chatgpt_account_id?: unknown
    }
    return quotaStr(payload['https://api.openai.com/auth']?.chatgpt_account_id)
      ?? quotaStr(payload['chatgpt_account_id'])
  } catch {
    return null
  }
}

/** 凭据：env CODEX_ACCESS_TOKEN(/CODEX_ACCOUNT_ID) 优先，其次 ~/.codex/auth.json */
export function readCodexAuth(home: string, env: NodeJS.ProcessEnv): CodexAuth | null {
  const envToken = env['CODEX_ACCESS_TOKEN']
  if (envToken && envToken.trim()) {
    return { token: envToken.trim(), accountId: env['CODEX_ACCOUNT_ID']?.trim() || null }
  }
  let raw: string
  try {
    raw = readFileSync(join(home, '.codex', 'auth.json'), 'utf8')
  } catch {
    return null
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch { return null }
  const root = parsed as Record<string, any>
  const tokens = (root?.tokens ?? {}) as Record<string, any>
  const token = quotaStr(tokens['access_token'])
  if (!token) return null
  const accountId = quotaStr(tokens['account_id']) ?? extractCodexAccountId(token)
  return { token, accountId }
}

function windowFrom(
  key: string, label: string, raw: unknown, now: number,
): QuotaWindow | null {
  if (raw === null || typeof raw !== 'object') return null
  const w = raw as Record<string, unknown>
  const usedPercent = toPercent(quotaNum(w['used_percent']) ?? quotaNum(w['utilization']))
  let resetAt = toEpochMs(w['reset_at'])
  if (resetAt === null) {
    const after = quotaNum(w['reset_after_seconds'])
    if (after !== null && after >= 0) resetAt = now + after * 1000
  }
  if (usedPercent === null && resetAt === null) return null
  return { key, label, usedPercent, percentage: usedPercent, nextResetAt: resetAt }
}

export async function fetchCodexAccount(
  auth: CodexAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${auth.token}`,
    accept: 'application/json',
    'user-agent': 'codex_cli_rs',
  }
  if (auth.accountId) headers['chatgpt-account-id'] = auth.accountId
  try {
    const { body } = await quotaFetchJson(
      doFetch, 'https://chatgpt.com/backend-api/wham/usage', { headers },
    )
    const root = (body ?? {}) as Record<string, any>
    const rateLimit = (root['rate_limit'] ?? {}) as Record<string, any>
    const windows: QuotaWindow[] = []
    const primary = windowFrom('fiveHour', '5 小时窗口', rateLimit['primary_window'], now)
    if (primary) windows.push(primary)
    const secondary = windowFrom('week', '周额度', rateLimit['secondary_window'], now)
    if (secondary) windows.push(secondary)
    // 重置卡（rate_limit_reset_credits）：available_count=持有张数，
    // applicable_available_count=当前额度状态下可用的张数；字段缺失（null）视为无此概念
    const resetCredits = (root['rate_limit_reset_credits'] ?? null) as Record<string, any> | null
    return finalizeAccount({
      kind: 'codex', label: 'Codex (ChatGPT)', provider: null,
      planName: quotaStr(root['plan_type']),
      windows, anySuccess: true, now,
      resetCredits: resetCredits ? quotaNum(resetCredits['available_count']) : null,
      applicableResetCredits: resetCredits ? quotaNum(resetCredits['applicable_available_count']) : null,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'codex', label: 'Codex (ChatGPT)', provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function codexAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readCodexAuth(home, env)
  if (!auth) return missingAccount('codex', 'Codex (ChatGPT)', now)
  return fetchCodexAccount(auth, doFetch, now)
}
