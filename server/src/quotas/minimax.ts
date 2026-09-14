// server/src/quotas/minimax.ts — MiniMax 编码订阅额度（移植 CodexBar MiniMaxUsageFetcher 的 remains 口径）：
// 凭据 = env MINIMAX_CODING_API_KEY / MINIMAX_API_KEY；
// GET {apiBase}/v1/token_plan/remains → 回退 /v1/api/openplatform/coding_plan/remains，
// 国际（minimax.io）失败换中国（minimaxi.com）；*_usage_count 字段是剩余量而非已用量。
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, percentOf, toEpochMs,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

const LABEL = 'MiniMax'

type Region = { apiBase: string }

const REGION_INTL: Region = { apiBase: 'https://api.minimax.io' }
const REGION_CN: Region = { apiBase: 'https://api.minimaxi.com' }

export function readMiniMaxAuth(env: NodeJS.ProcessEnv): { token: string; regions: Region[] } | null {
  const token = env['MINIMAX_CODING_API_KEY']?.trim() || env['MINIMAX_API_KEY']?.trim() || ''
  if (!token) return null
  const primary = env['MINIMAX_REGION']?.trim().toLowerCase() === 'cn' ? REGION_CN : REGION_INTL
  const other = primary === REGION_CN ? REGION_INTL : REGION_CN
  return { token, regions: [primary, other] }
}

/** 单条 model_remains → 窗口；intervals/weekly 的 usage_count 字段是剩余量 */
function windowFromItem(
  key: string, label: string, item: Record<string, unknown>,
  totalKey: string, remainingKey: string, remainingPercentKey: string, endKey: string,
): QuotaWindow | null {
  const total = quotaNum(item[totalKey])
  const remainingRaw = quotaNum(item[remainingKey])
  const remainingPercent = quotaNum(item[remainingPercentKey])
  const used = total !== null && remainingRaw !== null
    ? Math.max(0, total - remainingRaw)
    : null
  const percentage = percentOf(used, total)
    ?? (remainingPercent !== null ? Math.min(100, Math.max(0, 100 - remainingPercent)) : null)
  if (percentage === null && total === null) return null
  return {
    key, label,
    total, used, remaining: remainingRaw,
    percentage,
    nextResetAt: toEpochMs(item[endKey]),
  }
}

export async function fetchMiniMaxAccount(
  auth: { token: string; regions: Region[] }, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${auth.token}`,
    accept: 'application/json',
    'content-type': 'application/json',
    'mm-api-source': 'wattson-usage',
  }
  let body: unknown = null
  let lastErr: unknown = null
  let httpStatus: number | null = null
  outer: for (const region of auth.regions) {
    for (const path of ['/v1/token_plan/remains', '/v1/api/openplatform/coding_plan/remains']) {
      try {
        body = (await quotaFetchJson(doFetch, `${region.apiBase}${path}`, { headers })).body
        lastErr = null
        break outer
      } catch (err) {
        lastErr = err
        httpStatus = readHttpStatus(err)
      }
    }
  }
  if (lastErr !== null || body === null) {
    return finalizeAccount({
      kind: 'minimax', label: LABEL, provider: null,
      error: errText(lastErr), httpStatus, now,
    })
  }
  try {
    const root = (body ?? {}) as Record<string, any>
    const data = (root['data'] ?? {}) as Record<string, any>
    const baseResp = (data['base_resp'] ?? root['base_resp'] ?? null) as Record<string, any> | null
    const statusCode = quotaNum(baseResp?.['status_code'])
    if (statusCode !== null && statusCode !== 0) {
      const message = quotaStr(baseResp?.['status_message']) ?? `status_code ${statusCode}`
      const err: Error & { quotaHttpStatus?: number } = new Error(message)
      if (statusCode === 1004) err.quotaHttpStatus = 401
      throw err
    }
    const items = Array.isArray(data['model_remains']) ? data['model_remains'] : []
    if (items.length === 0) throw new Error('响应缺少 model_remains 数据')

    // 多模型 lane 取最吃紧的一个窗口口径
    let interval: QuotaWindow | null = null
    let week: QuotaWindow | null = null
    for (const raw of items) {
      if (raw === null || typeof raw !== 'object') continue
      const item = raw as Record<string, unknown>
      const candidateInterval = windowFromItem(
        'fiveHour', '5 小时窗口', item,
        'current_interval_total_count', 'current_interval_usage_count',
        'current_interval_remaining_percent', 'end_time',
      )
      if (candidateInterval && (interval === null || (candidateInterval.percentage ?? 0) > (interval.percentage ?? 0))) {
        interval = candidateInterval
      }
      const candidateWeek = windowFromItem(
        'week', '周额度', item,
        'current_weekly_total_count', 'current_weekly_usage_count',
        'current_weekly_remaining_percent', 'weekly_end_time',
      )
      if (candidateWeek && (week === null || (candidateWeek.percentage ?? 0) > (week.percentage ?? 0))) {
        week = candidateWeek
      }
    }
    const windows: QuotaWindow[] = []
    if (interval) windows.push(interval)
    if (week) windows.push(week)
    return finalizeAccount({
      kind: 'minimax', label: LABEL, provider: null,
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'minimax', label: LABEL, provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export function minimaxAccount(_home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const auth = readMiniMaxAuth(env)
  if (!auth) return missingAccount('minimax', LABEL, now)
  return fetchMiniMaxAccount(auth, doFetch, now)
}
