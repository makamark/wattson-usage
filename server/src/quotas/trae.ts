// server/src/quotas/trae.ts — Trae 订阅额度（参考 cockpit-tools
// trae_account_core_refresh.rs / trae_account_core_platform_storage.rs）：
// POST {origin}/trae/api/v1/pay/ide_user_pay_status 与 ide_user_ent_usage（require_usage），
// 头 Authorization: Bearer。origin 按区域：intl=grow-normal.trae.ai（备 growsg-normal.trae.ai），
// cn=grow-normal.trae.cn。响应包体 user_entitlement_pack_list[]，按 product_type 优先级
// [6,4,1,9,8,0] 取主包，重置时间在 entitlement_base_info.end_time（秒）。
// 注意：Trae IDE 本体把 token 存在 macOS 钥匙串（不做无感读取），
// 本模块支持 env（TRAE_ACCESS_TOKEN/TRAE_REGION）或凭据文件 ~/codeburn-agg/trae-auth.json。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, percentOf, quotaFetchJson, quotaNum, quotaStr,
  readHttpStatus, errText, toEpochMs,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export type TraeAuth = { token: string; region: 'cn' | 'intl' }

const REGION_HOSTS: Record<'cn' | 'intl', string[]> = {
  intl: ['https://grow-normal.trae.ai', 'https://growsg-normal.trae.ai'],
  cn: ['https://grow-normal.trae.cn', 'https://grow-normal.trae.ai'],
}

/** 凭据：env TRAE_ACCESS_TOKEN(+TRAE_REGION=cn|intl) 优先，其次 ~/codeburn-agg/trae-auth.json */
export function readTraeAuth(home: string, env: NodeJS.ProcessEnv): TraeAuth | null {
  const envToken = env['TRAE_ACCESS_TOKEN']
  if (envToken && envToken.trim()) {
    const region = env['TRAE_REGION']?.trim() === 'cn' ? 'cn' : 'intl'
    return { token: envToken.trim(), region }
  }
  let raw: string
  try {
    raw = readFileSync(join(home, 'codeburn-agg', 'trae-auth.json'), 'utf8')
  } catch {
    return null
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch { return null }
  const root = parsed as Record<string, any>
  const token = quotaStr(root['accessToken']) ?? quotaStr(root['access_token']) ?? quotaStr(root['token'])
  if (!token) return null
  return { token, region: root['region'] === 'cn' ? 'cn' : 'intl' }
}

const PRODUCT_TYPE_ORDER = [6, 4, 1, 9, 8, 0]

function packProductType(pack: Record<string, unknown>): number | null {
  return quotaNum(pack['product_type']) ?? quotaNum(pack['productType'])
}

/** 主资源包 → 窗口：数字字段名在响应中不完全稳定，做宽口径提取 */
function windowFromPack(pack: Record<string, unknown>): QuotaWindow {
  const total = quotaNum(pack['entitlement_total']) ?? quotaNum(pack['total']) ?? quotaNum(pack['limit'])
    ?? quotaNum(pack['capacity']) ?? quotaNum(pack['CapacitySize'])
  const used = quotaNum(pack['entitlement_used']) ?? quotaNum(pack['used']) ?? quotaNum(pack['Usage'])
    ?? quotaNum(pack['used_num']) ?? quotaNum(pack['CapacityUsed'])
  const remain = quotaNum(pack['entitlement_remain']) ?? quotaNum(pack['remaining']) ?? quotaNum(pack['remain'])
    ?? quotaNum(pack['CapacityRemain'])
  const resetAt = toEpochMs(
    (pack['entitlement_base_info'] as Record<string, unknown> | undefined)?.['end_time']
      ?? pack['end_time'] ?? pack['reset_time'],
  )
  return {
    key: 'cycle', label: '周期额度',
    total: total ?? null, used: used ?? null, remaining: remain ?? null,
    percentage: percentOf(used, total),
    nextResetAt: resetAt,
  }
}

export function traeWindows(usageBody: unknown): { windows: QuotaWindow[]; planName: string | null } {
  const root = usageBody as Record<string, any>
  const list = root?.user_entitlement_pack_list
  let planName: string | null = null
  const windows: QuotaWindow[] = []
  if (Array.isArray(list) && list.length > 0) {
    const packs = list.filter((p): p is Record<string, unknown> => p !== null && typeof p === 'object')
    const pick = (type: number): Record<string, unknown> | undefined =>
      packs.find(p => packProductType(p) === type)
    const main = PRODUCT_TYPE_ORDER.map(pick).find(Boolean)
    if (main) windows.push(windowFromPack(main))
    const identity = main ? quotaStr(main['product_name']) ?? quotaStr(main['plan_name']) : null
    planName = identity
  }
  return { windows, planName }
}

async function postTrae(doFetch: FetchLike, origin: string, path: string, token: string, body: unknown): Promise<{ status: number; body: unknown }> {
  return quotaFetchJson(doFetch, `${origin}${path}`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      accept: 'application/json',
    },
    body: JSON.stringify(body),
  })
}

export async function fetchTraeAccount(
  auth: TraeAuth, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const origins = REGION_HOSTS[auth.region]
  let lastErr: unknown = null
  for (const origin of origins) {
    try {
      const { body } = await postTrae(doFetch, origin, '/trae/api/v1/pay/ide_user_ent_usage', auth.token, { require_usage: true })
      const { windows, planName } = traeWindows(body)
      return finalizeAccount({
        kind: 'trae', label: 'Trae', provider: null,
        planName, windows, anySuccess: true, now,
      })
    } catch (err) {
      lastErr = err
      // 401/403 没必要换 origin 重试
      if (readHttpStatus(err) === 401 || readHttpStatus(err) === 403) break
    }
  }
  return finalizeAccount({
    kind: 'trae', label: 'Trae', provider: null,
    error: lastErr ? errText(lastErr) : 'no reachable origin',
    httpStatus: lastErr ? readHttpStatus(lastErr) : null,
    now,
  })
}

export function traeAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readTraeAuth(home, env)
  if (!auth) return missingAccount('trae', 'Trae', now)
  return fetchTraeAccount(auth, doFetch, now)
}
