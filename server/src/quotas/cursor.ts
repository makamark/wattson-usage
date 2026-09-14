// server/src/quotas/cursor.ts — Cursor 订阅额度（参考 cockpit-tools cursor_account.rs）：
// GET https://cursor.com/api/usage-summary，认证走 Cookie
// `WorkosCursorSessionToken=<userId>%3A%3A<accessToken>`（userId 取自 accessToken JWT 的 sub）。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, quotaNum, quotaStr,
  readHttpStatus, errText, toEpochMs, toPercent,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export type CursorAuth = { token: string }

/** 从 JWT payload 取 WorkOS 用户 id（sub / user_id / userId） */
export function extractCursorUserId(token: string): string | null {
  const parts = token.split('.')
  if (parts.length !== 3) return null
  try {
    const payload = JSON.parse(Buffer.from(parts[1]!, 'base64url').toString('utf8')) as Record<string, unknown>
    return quotaStr(payload['sub']) ?? quotaStr(payload['user_id']) ?? quotaStr(payload['userId'])
  } catch {
    return null
  }
}

/** 凭据：env CURSOR_ACCESS_TOKEN 优先；其次 ~/.cursor/auth.json | credentials.json 的 accessToken */
export function readCursorAuth(home: string, env: NodeJS.ProcessEnv): CursorAuth | null {
  const envToken = env['CURSOR_ACCESS_TOKEN']
  if (envToken && envToken.trim()) return { token: envToken.trim() }
  for (const name of ['auth.json', 'credentials.json']) {
    let raw: string
    try {
      raw = readFileSync(join(home, '.cursor', name), 'utf8')
    } catch { continue }
    let parsed: unknown
    try { parsed = JSON.parse(raw) } catch { continue }
    const root = parsed as Record<string, any>
    const token = quotaStr(root['accessToken']) ?? quotaStr(root['access_token'])
      ?? quotaStr((root['cursorAuth'] ?? {})['accessToken'])
    if (token) return { token }
  }
  return null
}

/** usage-summary 响应是演进中的结构：优先 prompts.secondary/primary，兼容 quotaDisplay[] */
function cursorWindows(root: Record<string, any>): QuotaWindow[] {
  const windows: QuotaWindow[] = []
  const prompts = (root['prompts'] ?? {}) as Record<string, any>
  const fromWindow = (key: string, label: string, raw: unknown): QuotaWindow | null => {
    if (raw === null || typeof raw !== 'object') return null
    const w = raw as Record<string, unknown>
    const usedPercent = toPercent(
      quotaNum(w['usedPercentage']) ?? quotaNum(w['used_percent']) ?? quotaNum(w['utilization']),
    )
    const resetAt = toEpochMs(w['resetDate'] ?? w['reset_date'] ?? w['nextResetTime'])
    if (usedPercent === null && resetAt === null) return null
    return { key, label, usedPercent, percentage: usedPercent, nextResetAt: resetAt }
  }
  const primary = fromWindow('fiveHour', '5 小时窗口', prompts['primary'] ?? prompts['primary_window'])
  if (primary) windows.push(primary)
  const secondary = fromWindow('cycle', '周期额度', prompts['secondary'] ?? prompts['secondary_window'])
  if (secondary) windows.push(secondary)
  if (windows.length === 0 && Array.isArray(root['quotaDisplay'])) {
    for (const item of root['quotaDisplay'] as Array<Record<string, unknown>>) {
      const label = quotaStr(item['name']) ?? '额度窗口'
      const w = fromWindow(String(item['name'] ?? 'cycle'), label, item)
      if (w) windows.push(w)
    }
  }
  return windows
}

export async function fetchCursorAccount(
  auth: CursorAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const userId = extractCursorUserId(auth.token)
  if (!userId) {
    return finalizeAccount({
      kind: 'cursor', label: 'Cursor', provider: null,
      error: 'accessToken 不是合法 JWT（缺少 WorkOS 用户 id）', now,
    })
  }
  const headers = {
    accept: 'application/json',
    cookie: `WorkosCursorSessionToken=${userId}%3A%3A${auth.token}`,
    'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
  }
  try {
    const { body } = await quotaFetchJson(
      doFetch, 'https://cursor.com/api/usage-summary', { headers },
    )
    const root = (body ?? {}) as Record<string, any>
    const windows = cursorWindows(root)
    return finalizeAccount({
      kind: 'cursor', label: 'Cursor', provider: null,
      planName: quotaStr(root['membershipType']),
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'cursor', label: 'Cursor', provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function cursorAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readCursorAuth(home, env)
  if (!auth) return missingAccount('cursor', 'Cursor', now)
  return fetchCursorAccount(auth, doFetch, now)
}
