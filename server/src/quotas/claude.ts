// server/src/quotas/claude.ts — Claude Code 订阅额度（参考 cockpit-tools
// claude_account_core_storage.rs）：GET https://api.anthropic.com/api/oauth/usage，
// 头 Authorization: Bearer + anthropic-beta: oauth-2025-04-20（Claude Code OAuth 口径）。
// 响应窗口：five_hour / seven_day / seven_day_sonnet / extra_usage，utilization 兼容 0-1 与 0-100。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, toEpochMs, toPercent,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export type ClaudeAuth = { token: string }

/** 凭据：env CLAUDE_ACCESS_TOKEN 优先，其次 ~/.claude/.credentials.json 的 claudeAiOauth */
export function readClaudeAuth(home: string, env: NodeJS.ProcessEnv): ClaudeAuth | null {
  const envToken = env['CLAUDE_ACCESS_TOKEN']
  if (envToken && envToken.trim()) return { token: envToken.trim() }
  let raw: string
  try {
    raw = readFileSync(join(home, '.claude', '.credentials.json'), 'utf8')
  } catch {
    return null
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch { return null }
  const root = parsed as Record<string, any>
  const oauth = (root?.claudeAiOauth ?? {}) as Record<string, any>
  const token = quotaStr(oauth['accessToken']) ?? quotaStr(root['accessToken'])
  return token ? { token } : null
}

function claudeWindow(
  key: string, label: string, raw: unknown,
): QuotaWindow | null {
  if (raw === null || typeof raw !== 'object') return null
  const w = raw as Record<string, unknown>
  const usedPercent = toPercent(
    quotaNum(w['utilization']) ?? quotaNum(w['used_percent']) ?? quotaNum(w['percentage']),
  )
  const resetAt = toEpochMs(w['resets_at'] ?? w['reset_at'] ?? w['reset_after_seconds'])
  if (usedPercent === null && resetAt === null) return null
  return { key, label, usedPercent, percentage: usedPercent, nextResetAt: resetAt }
}

export async function fetchClaudeAccount(
  auth: ClaudeAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers = {
    authorization: `Bearer ${auth.token}`,
    'anthropic-beta': 'oauth-2025-04-20',
    accept: 'application/json',
    'user-agent': 'claude-cli',
  }
  try {
    const { body } = await quotaFetchJson(
      doFetch, 'https://api.anthropic.com/api/oauth/usage', { headers },
    )
    const root = (body ?? {}) as Record<string, any>
    const windows: QuotaWindow[] = []
    const spec: Array<[string, string, string]> = [
      ['fiveHour', '5 小时窗口', 'five_hour'],
      ['week', '周额度', 'seven_day'],
      ['weekSonnet', '周额度（Sonnet）', 'seven_day_sonnet'],
      ['extra', '额外用量', 'extra_usage'],
    ]
    for (const [key, label, field] of spec) {
      const w = claudeWindow(key, label, root[field])
      if (w) windows.push(w)
    }
    return finalizeAccount({
      kind: 'claude', label: 'Claude Code', provider: null,
      planName: quotaStr(root['plan_type']),
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'claude', label: 'Claude Code', provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function claudeAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readClaudeAuth(home, env)
  if (!auth) return missingAccount('claude', 'Claude Code', now)
  return fetchClaudeAccount(auth, doFetch, now)
}
