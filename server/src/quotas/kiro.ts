// server/src/quotas/kiro.ts — Kiro (AWS CodeWhisperer) 用量限额（移植 CodexBar KiroUsageLimitsAPI）：
// 凭据 = env KIRO_ACCESS_TOKEN+KIRO_PROFILE_ARN，或 kiro-cli 本地 SQLite（只读，经系统 sqlite3 CLI）：
//   macOS ~/Library/Application Support/kiro-cli/data.sqlite3，Linux $XDG_DATA_HOME|~/.local/share /kiro-cli/data.sqlite3
//   auth_kv['kirocli:odic:token'].access_token + state['api.codewhisperer.profile'].arn；
// POST {codewhisperer|q}.amazonaws.com/，头 X-Amz-Target: GetUsageLimits，body {profileArn}。
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, percentOf, toEpochMs,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

const LABEL = 'Kiro'

export type KiroAuth = { accessToken: string; profileArn: string }
type RunLike = (file: string, args: string[]) => Promise<{ stdout: string; stderr: string }>

const runProcess: RunLike = (file, args) => new Promise((resolve, reject) => {
  execFile(file, args, { timeout: 5_000, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
    if (err) reject(err)
    else resolve({ stdout: String(stdout), stderr: String(stderr) })
  })
})

const REGION_ENDPOINTS: Record<string, string> = {
  'us-east-1': 'https://codewhisperer.us-east-1.amazonaws.com/',
  'eu-central-1': 'https://q.eu-central-1.amazonaws.com/',
}

export function kiroStateDatabasePath(home: string, env: NodeJS.ProcessEnv): string | null {
  const override = env['KIRO_DATA_DIR']?.trim()
  if (override) return join(override, 'data.sqlite3')
  if (process.platform === 'darwin') {
    return join(home, 'Library', 'Application Support', 'kiro-cli', 'data.sqlite3')
  }
  const dataHome = env['XDG_DATA_HOME']?.trim() || join(home, '.local', 'share')
  return join(dataHome, 'kiro-cli', 'data.sqlite3')
}

async function querySqliteValue(
  run: RunLike, dbPath: string, sql: string,
): Promise<Record<string, unknown> | null> {
  if (!existsSync(dbPath)) return null
  const { stdout } = await run('sqlite3', ['-json', dbPath, sql])
  const rows = JSON.parse(stdout.trim()) as Array<{ value?: unknown }>
  const raw = rows[0]?.['value']
  if (typeof raw !== 'string' || !raw.trim()) return null
  try { return JSON.parse(raw) as Record<string, unknown> } catch { return null }
}

export async function readKiroAuth(
  home: string, env: NodeJS.ProcessEnv, run: RunLike = runProcess,
): Promise<KiroAuth | null> {
  const envToken = env['KIRO_ACCESS_TOKEN']?.trim()
  const envArn = env['KIRO_PROFILE_ARN']?.trim()
  if (envToken && envArn) return { accessToken: envToken, profileArn: envArn }
  const dbPath = kiroStateDatabasePath(home, env)
  if (!dbPath) return null
  try {
    const tokenJson = await querySqliteValue(
      run, dbPath, "SELECT value FROM auth_kv WHERE key = 'kirocli:odic:token'",
    )
    const accessToken = typeof tokenJson?.['access_token'] === 'string' ? tokenJson['access_token'] : null
    const profileJson = await querySqliteValue(
      run, dbPath, "SELECT value FROM state WHERE key = 'api.codewhisperer.profile'",
    )
    const profileArn = typeof profileJson?.['arn'] === 'string' ? profileJson['arn'] : null
    if (accessToken && profileArn) return { accessToken, profileArn }
  } catch {
    // sqlite3 缺失或库损坏 → 视为无凭据
  }
  return null
}

/** arn:aws:codewhisperer:<region>:...:profile/<name> → 端点；不支持的区域返回 null */
export function kiroEndpointForArn(profileArn: string): string | null {
  const parts = profileArn.split(':')
  if (parts.length !== 6 || parts[0] !== 'arn' || parts[1] !== 'aws' || parts[2] !== 'codewhisperer') return null
  if (!parts[5]!.startsWith('profile/') || parts[5]!.length <= 'profile/'.length) return null
  return REGION_ENDPOINTS[parts[3]!] ?? null
}

export async function fetchKiroAccount(
  auth: KiroAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const endpoint = kiroEndpointForArn(auth.profileArn)
  if (!endpoint) {
    return finalizeAccount({
      kind: 'kiro', label: LABEL, provider: null,
      error: `unsupported profile ARN: ${auth.profileArn}`, httpStatus: null, now,
    })
  }
  const headers: Record<string, string> = {
    'content-type': 'application/x-amz-json-1.0',
    'x-amz-target': 'AmazonCodeWhispererService.GetUsageLimits',
    authorization: `Bearer ${auth.accessToken}`,
  }
  try {
    const { body } = await quotaFetchJson(doFetch, endpoint, {
      method: 'POST', headers, body: JSON.stringify({ profileArn: auth.profileArn }),
    })
    const root = (body ?? {}) as Record<string, any>
    const breakdown = Array.isArray(root['usageBreakdownList']) ? root['usageBreakdownList'] : []
    const credit = breakdown.find((b: Record<string, any>) => b['resourceType'] === 'CREDIT') ?? null
    if (!credit) throw new Error('响应未报告 CREDIT 用量')
    const total = quotaNum(credit['usageLimitWithPrecision'])
    const totalUsed = quotaNum(credit['currentUsageWithPrecision'])
    const overageUsed = quotaNum(credit['currentOveragesWithPrecision']) ?? 0
    if (total === null || totalUsed === null) throw new Error('CREDIT 条目缺少 limit/usage')
    // currentUsage 含 overage；planUsed 才对应订阅口径
    const planUsed = Math.max(0, totalUsed - Math.max(0, overageUsed))
    const resetRaw = quotaNum(credit['nextDateReset']) ?? quotaNum(root['nextDateReset'])
    // 合理的 Unix 秒区间（2001-2100）；毫秒或其它单位不可信
    const resetAt = resetRaw !== null && resetRaw >= 1e9 && resetRaw <= 4_102_444_800
      ? resetRaw * 1000 : null
    const windows: QuotaWindow[] = [{
      key: 'cycle', label: '周期额度',
      total, used: planUsed, remaining: Math.max(0, total - planUsed),
      percentage: percentOf(planUsed, total),
      nextResetAt: resetAt,
    }]
    return finalizeAccount({
      kind: 'kiro', label: LABEL, provider: null,
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'kiro', label: LABEL, provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export async function kiroAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): Promise<QuotaAccount> {
  const auth = await readKiroAuth(home, env)
  if (!auth) return missingAccount('kiro', LABEL, now)
  return fetchKiroAccount(auth, doFetch, now)
}
