// server/src/quotas/zed.ts — Zed 订阅额度（移植 CodexBar ZedStatusProbe）：
// 凭据 = env ZED_ACCESS_TOKEN+ZED_USER_ID（或显式 ZED_KEYCHAIN=1 后读 macOS 钥匙串
// server/service = https://zed.dev，account = userID，password = access token）；
// GET https://cloud.zed.dev/client/users/me，注意 Authorization 头是 "<userID> <accessToken>" 而非 Bearer。
import { execFile } from 'node:child_process'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, toEpochMs, percentOf,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

const LABEL = 'Zed'
const KEYCHAIN_SERVICE = 'https://zed.dev'

export type ZedAuth = { userId: string; token: string }
type RunLike = (file: string, args: string[]) => Promise<{ stdout: string; stderr: string }>

const runProcess: RunLike = (file, args) => new Promise((resolve, reject) => {
  execFile(file, args, { timeout: 5_000 }, (err, stdout, stderr) => {
    if (err) reject(err)
    else resolve({ stdout: String(stdout), stderr: String(stderr) })
  })
})

/** 从 security 输出里抽 "acct"<blob>="123" 形式的属性 */
function extractAcct(output: string): string | null {
  return quotaStr(output.match(/"acct"<blob>="([^"]+)"/)?.[1])
}

async function keychainCredentials(run: RunLike): Promise<ZedAuth | null> {
  // CodexBar 顺序：先 internet password，再 generic password
  for (const kind of ['find-internet-password', 'find-generic-password']) {
    try {
      const attrs = await run('/usr/bin/security', [kind, '-s', KEYCHAIN_SERVICE])
      const userId = extractAcct(attrs.stdout + attrs.stderr)
      const password = await run('/usr/bin/security', [kind, '-s', KEYCHAIN_SERVICE, '-w'])
      const token = password.stdout.trim()
      if (userId && token) return { userId, token }
    } catch {
      // 换下一种钥匙串条目
    }
  }
  return null
}

/** 凭据：env ZED_ACCESS_TOKEN+ZED_USER_ID 优先；其次 macOS 钥匙串（须显式 ZED_KEYCHAIN=1
 * 开启——headless LaunchAgent 下主动读他应用钥匙串可能弹授权框，默认不碰）。 */
export async function readZedAuth(
  env: NodeJS.ProcessEnv,
  run: RunLike = runProcess,
): Promise<ZedAuth | null> {
  const envToken = env['ZED_ACCESS_TOKEN']
  if (envToken?.trim() && env['ZED_USER_ID']?.trim()) {
    return { userId: env['ZED_USER_ID'].trim(), token: envToken.trim() }
  }
  if (env['ZED_KEYCHAIN'] !== '1') return null
  if (process.platform !== 'darwin') return null
  return keychainCredentials(run)
}

export async function fetchZedAccount(
  auth: ZedAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    // Zed 协议："<userID> <accessToken>"，不是 Bearer
    authorization: `${auth.userId} ${auth.token}`,
    accept: 'application/json',
  }
  try {
    const { body } = await quotaFetchJson(
      doFetch, 'https://cloud.zed.dev/client/users/me', { headers },
    )
    const root = (body ?? {}) as Record<string, any>
    const plan = (root['plan'] ?? null) as Record<string, any> | null
    if (!plan) throw new Error('响应缺少 plan 字段')
    const editPredictions = (plan['usage']?.['edit_predictions'] ?? null) as Record<string, any> | null
    const period = (plan['subscription_period'] ?? null) as Record<string, any> | null

    const windows: QuotaWindow[] = []
    const limit = editPredictions ? quotaNum(editPredictions['limit']) : null
    const used = editPredictions ? quotaNum(editPredictions['used']) : null
    // limit 可能是字符串 "unlimited"（quotaNum → null），此时不展示该窗口
    if (limit !== null && used !== null) {
      windows.push({
        key: 'editPredictions', label: 'Edit Predictions',
        total: limit, used, remaining: Math.max(0, limit - used),
        percentage: percentOf(used, limit),
        nextResetAt: period ? toEpochMs(period['ended_at']) : null,
      })
    }
    // 账期进度：按订阅周期已过时间折算
    const startedAt = period ? toEpochMs(period['started_at']) : null
    const endedAt = period ? toEpochMs(period['ended_at']) : null
    if (startedAt !== null && endedAt !== null && endedAt > startedAt) {
      const elapsed = Math.min(100, Math.max(0, (now - startedAt) / (endedAt - startedAt) * 100))
      windows.push({
        key: 'cycle', label: '账期进度', usedPercent: elapsed, percentage: elapsed, nextResetAt: endedAt,
      })
    }
    return finalizeAccount({
      kind: 'zed', label: LABEL, provider: null,
      planName: quotaStr(plan['plan_v3']),
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'zed', label: LABEL, provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export async function zedAccount(_home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): Promise<QuotaAccount> {
  const auth = await readZedAuth(env)
  if (!auth) return missingAccount('zed', LABEL, now)
  return fetchZedAccount(auth, doFetch, now)
}
