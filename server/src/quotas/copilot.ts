// server/src/quotas/copilot.ts — GitHub Copilot 订阅额度（移植 CodexBar CopilotUsageFetcher）：
// 凭据 = env COPILOT_API_TOKEN（GitHub OAuth token；设备流授权不在服务端做）；
// GET https://api.github.com/copilot_internal/user，头 Authorization: token + Copilot 伪装头；
// quota_snapshots.premium_interactions / chat → usedPercent = 100 - percent_remaining。
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, toEpochMs, toPercent,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

const LABEL = 'Copilot'

/** quota_snapshots 子窗口：unlimited / 占位（entitlement==0 && remaining==0）丢弃 */
function windowFrom(
  key: string, label: string, raw: unknown,
): QuotaWindow | null {
  if (raw === null || typeof raw !== 'object') return null
  const s = raw as Record<string, unknown>
  if (s['unlimited'] === true) return null
  const entitlement = quotaNum(s['entitlement'])
  const remaining = quotaNum(s['remaining'])
  if (entitlement === 0 && remaining === 0) return null
  const percentRemaining = toPercent(quotaNum(s['percent_remaining']))
  if (percentRemaining === null) return null
  return {
    key, label,
    total: entitlement, used: entitlement !== null && remaining !== null ? entitlement - remaining : null,
    remaining,
    usedPercent: 100 - percentRemaining,
    percentage: 100 - percentRemaining,
    nextResetAt: null,
  }
}

export function readCopilotAuth(env: NodeJS.ProcessEnv): string | null {
  const token = env['COPILOT_API_TOKEN']
  return token && token.trim() ? token.trim() : null
}

export async function fetchCopilotAccount(
  token: string, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    authorization: `token ${token}`,
    accept: 'application/json',
    'editor-version': 'vscode/1.96.2',
    'editor-plugin-version': 'copilot-chat/0.26.7',
    'user-agent': 'GitHubCopilotChat/0.26.7',
    'x-github-api-version': '2025-04-01',
  }
  try {
    const { body } = await quotaFetchJson(
      doFetch, 'https://api.github.com/copilot_internal/user', { headers },
    )
    const root = (body ?? {}) as Record<string, any>
    const snapshots = (root['quota_snapshots'] ?? null) as Record<string, any> | null
    const resetAt = toEpochMs(root['quota_reset_date'])
    const windows: QuotaWindow[] = []
    const premium = snapshots ? windowFrom('premium', 'Premium 请求', snapshots['premium_interactions']) : null
    if (premium) { premium.nextResetAt = resetAt; windows.push(premium) }
    const chat = snapshots ? windowFrom('chat', 'Chat', snapshots['chat']) : null
    if (chat) { chat.nextResetAt = resetAt; windows.push(chat) }
    return finalizeAccount({
      kind: 'copilot', label: LABEL, provider: null,
      planName: quotaStr(root['copilot_plan']),
      windows, anySuccess: snapshots !== null, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'copilot', label: LABEL, provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function copilotAccount(_home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const token = readCopilotAuth(env)
  if (!token) return missingAccount('copilot', LABEL, now)
  return fetchCopilotAccount(token, doFetch, now)
}
