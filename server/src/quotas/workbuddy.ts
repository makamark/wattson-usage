// server/src/quotas/workbuddy.ts — WorkBuddy 订阅额度（参考 cockpit-tools
// workbuddy_oauth.rs）：POST https://copilot.tencent.com/v2/billing/meter/get-user-resource，
// 头 Authorization: Bearer + X-User-Id / X-Enterprise-Id / X-Tenant-Id / X-Domain。
// 响应是腾讯云计费形态：data.Response.Data.Accounts[].CycleCapacity{Size,Used,Remain}。
// 注意：WorkBuddy IDE 本体把 token 存在 macOS 钥匙串（不做无感读取），
// 本模块支持 env（WORKBUDDY_ACCESS_TOKEN…）或凭据文件 ~/codeburn-agg/workbuddy-auth.json。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, percentOf, quotaFetchJson, quotaNum, quotaStr,
  readHttpStatus, errText, toEpochMs,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export type WorkbuddyAuth = {
  token: string
  uid?: string | null
  enterpriseId?: string | null
  domain?: string | null
}

const DEFAULT_HOST = 'https://copilot.tencent.com'

/** 凭据：env WORKBUDDY_ACCESS_TOKEN(+WORKBUDDY_UID/WORKBUDDY_ENTERPRISE_ID/WORKBUDDY_DOMAIN)
 *  优先，其次 ~/codeburn-agg/workbuddy-auth.json（accessToken/access_token + uid/enterpriseId/domain） */
export function readWorkbuddyAuth(home: string, env: NodeJS.ProcessEnv): WorkbuddyAuth | null {
  const envToken = env['WORKBUDDY_ACCESS_TOKEN']
  if (envToken && envToken.trim()) {
    return {
      token: envToken.trim(),
      uid: env['WORKBUDDY_UID']?.trim() || null,
      enterpriseId: env['WORKBUDDY_ENTERPRISE_ID']?.trim() || null,
      domain: env['WORKBUDDY_DOMAIN']?.trim() || null,
    }
  }
  let raw: string
  try {
    raw = readFileSync(join(home, 'codeburn-agg', 'workbuddy-auth.json'), 'utf8')
  } catch {
    return null
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch { return null }
  const root = parsed as Record<string, any>
  const token = quotaStr(root['accessToken']) ?? quotaStr(root['access_token']) ?? quotaStr(root['token'])
  if (!token) return null
  return {
    token,
    uid: quotaStr(root['uid']),
    enterpriseId: quotaStr(root['enterpriseId']) ?? quotaStr(root['enterprise_id']),
    domain: quotaStr(root['domain']),
  }
}

function authHeaders(auth: WorkbuddyAuth): Record<string, string> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${auth.token}`,
    'content-type': 'application/json',
    accept: 'application/json, text/plain, */*',
  }
  if (auth.uid) headers['x-user-id'] = auth.uid
  if (auth.enterpriseId) {
    headers['x-enterprise-id'] = auth.enterpriseId
    headers['x-tenant-id'] = auth.enterpriseId
  }
  if (auth.domain) headers['x-domain'] = auth.domain
  return headers
}

/** 腾讯云资源包 → 统一窗口：CycleCapacity{Size,Used,Remain} + CycleEndTime/ResetTime */
export function workbuddyWindows(resourceBody: unknown): QuotaWindow[] {
  const root = resourceBody as Record<string, any>
  const accounts = root?.data?.Response?.Data?.Accounts
  if (!Array.isArray(accounts)) return []
  const windows: QuotaWindow[] = []
  for (const account of accounts) {
    if (account === null || typeof account !== 'object') continue
    const a = account as Record<string, unknown>
    const total = quotaNum(a['CycleCapacitySize']) ?? quotaNum(a['CapacitySize'])
    const used = quotaNum(a['CycleCapacityUsed']) ?? quotaNum(a['CapacityUsed'])
    const remain = quotaNum(a['CycleCapacityRemain']) ?? quotaNum(a['CapacityRemain'])
    const unlimited = a['Unlimited'] === true
    if (total === null && used === null && !unlimited) continue
    windows.push({
      key: 'cycle',
      label: unlimited ? '周期额度（不限量）' : '周期额度',
      total: total ?? null,
      used: used ?? null,
      remaining: unlimited ? null : (remain ?? Math.max(0, (total ?? 0) - (used ?? 0))),
      percentage: unlimited ? 0 : percentOf(used, total),
      nextResetAt: toEpochMs(a['CycleEndTime'] ?? a['CycleResetTime'] ?? a['CycleStartTime']),
    })
  }
  return windows
}

export async function fetchWorkbuddyAccount(
  auth: WorkbuddyAuth, doFetch: FetchLike, now: number, host = DEFAULT_HOST,
): Promise<QuotaAccount> {
  const headers = authHeaders(auth)
  try {
    const { body } = await quotaFetchJson(doFetch, `${host}/v2/billing/meter/get-user-resource`, {
      method: 'POST', headers, body: JSON.stringify({}),
    })
    const windows = workbuddyWindows(body)
    return finalizeAccount({
      kind: 'workbuddy', label: 'WorkBuddy', provider: null,
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'workbuddy', label: 'WorkBuddy', provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function workbuddyAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readWorkbuddyAuth(home, env)
  if (!auth) return missingAccount('workbuddy', 'WorkBuddy', now)
  const host = env['WORKBUDDY_API_HOST']?.trim() || DEFAULT_HOST
  return fetchWorkbuddyAccount(auth, doFetch, now, host)
}
