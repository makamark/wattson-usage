// server/src/quotas/factory.ts — Factory 订阅额度（移植 CodexBar FactoryStatusProbe 的 API-key 口径）：
// 凭据 = env FACTORY_API_KEY 或 ~/.factory/.env 的 FACTORY_API_KEY= 行；
// GET https://api.factory.ai/api/billing/limits（失败回退 app.factory.ai）；
// limits.standard.{fiveHour,weekly,monthly} = 5h/周/月三窗口（纯百分比 + windowEnd/secondsRemaining）。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, toEpochMs, toPercent,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

export function readFactoryApiKey(home: string, env: NodeJS.ProcessEnv): string | null {
  const envKey = env['FACTORY_API_KEY']
  if (envKey && envKey.trim()) return envKey.trim()
  let contents: string
  try {
    contents = readFileSync(join(home, '.factory', '.env'), 'utf8')
  } catch {
    return null
  }
  for (const rawLine of contents.split(/\r?\n/)) {
    let line = rawLine.trim()
    if (!line || line.startsWith('#')) continue
    if (line.startsWith('export ')) line = line.slice('export '.length).trim()
    const eq = line.indexOf('=')
    if (eq < 0) continue
    if (line.slice(0, eq).trim() !== 'FACTORY_API_KEY') continue
    const value = line.slice(eq + 1).trim().replace(/^["']|["']$/g, '')
    if (value) return value
  }
  return null
}

/** 单窗口：usedPercent 直接给；windowEnd 兼容 epoch 秒/毫秒/ISO；过期窗口视为已重置（0%） */
function windowFrom(
  key: string, label: string, raw: unknown, now: number,
): QuotaWindow | null {
  if (raw === null || typeof raw !== 'object') return null
  const w = raw as Record<string, unknown>
  const secondsRemaining = quotaNum(w['secondsRemaining'])
  let resetAt: number | null = null
  if (secondsRemaining !== null && secondsRemaining > 0) resetAt = now + secondsRemaining * 1000
  const windowEnd = toEpochMs(w['windowEnd'])
  if (resetAt === null && windowEnd !== null && windowEnd > now) resetAt = windowEnd
  const expired = resetAt === null && windowEnd !== null
  const usedPercent = expired ? 0 : toPercent(quotaNum(w['usedPercent']))
  if (usedPercent === null) return null
  return {
    key, label,
    usedPercent: Math.min(100, Math.max(0, usedPercent)),
    percentage: Math.min(100, Math.max(0, usedPercent)),
    nextResetAt: resetAt,
  }
}

export async function fetchFactoryAccount(
  apiKey: string, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${apiKey}`,
    accept: 'application/json',
    'x-factory-client': 'wattson-usage',
  }
  let body: unknown = null
  let lastErr: unknown = null
  let httpStatus: number | null = null
  for (const base of ['https://api.factory.ai', 'https://app.factory.ai']) {
    try {
      body = (await quotaFetchJson(doFetch, `${base}/api/billing/limits`, { headers })).body
      lastErr = null
      break
    } catch (err) {
      lastErr = err
      httpStatus = readHttpStatus(err)
    }
  }
  if (lastErr !== null || body === null) {
    return finalizeAccount({
      kind: 'factory', label: 'Factory', provider: null,
      error: errText(lastErr), httpStatus, now,
    })
  }
  const root = (body ?? {}) as Record<string, any>
  const standard = (root['limits']?.['standard'] ?? null) as Record<string, any> | null
  const windows: QuotaWindow[] = []
  const fiveHour = standard ? windowFrom('fiveHour', '5 小时窗口', standard['fiveHour'], now) : null
  if (fiveHour) windows.push(fiveHour)
  const weekly = standard ? windowFrom('week', '周额度', standard['weekly'], now) : null
  if (weekly) windows.push(weekly)
  const monthly = standard ? windowFrom('cycle', '月度额度', standard['monthly'], now) : null
  if (monthly) windows.push(monthly)
  return finalizeAccount({
    kind: 'factory', label: 'Factory', provider: null,
    windows, anySuccess: standard !== null, now,
  })
}

export function factoryAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): QuotaAccount | Promise<QuotaAccount> {
  const apiKey = readFactoryApiKey(home, env)
  if (!apiKey) return missingAccount('factory', 'Factory', now)
  return fetchFactoryAccount(apiKey, doFetch, now)
}
