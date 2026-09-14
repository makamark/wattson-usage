// server/src/quotas/gemini.ts — Gemini CLI（oauth-personal）订阅额度（移植 CodexBar GeminiStatusProbe）：
// 凭据 = ~/.gemini/oauth_creds.json（access_token/refresh_token/expiry_date），settings.json 的
// selectedType 不能是 api-key；过期时用 refresh_token + OAuth client（env 或从本机 gemini-cli
// 安装文件里抽取）刷新并回写；loadCodeAssist → retrieveUserQuota，buckets 按模型取最低剩余比例。
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  finalizeAccount, missingAccount, quotaFetchJson, readHttpStatus, errText,
  quotaNum, quotaStr, toEpochMs,
  type FetchLike, type QuotaAccount, type QuotaWindow,
} from './types.js'

const LABEL = 'Gemini'

export type GeminiCreds = {
  accessToken: string | null
  refreshToken: string | null
  expiryMs: number | null
  /** 已解析/抽取到的 OAuth client；用于静默刷新 */
  clientId: string | null
  clientSecret: string | null
  credsPath: string
}

const TIER_NAMES: Record<string, string> = {
  'free-tier': 'Free',
  'legacy-tier': 'Legacy',
  'standard-tier': 'Standard',
}

/** gemini-cli 安装里 oauth2.js 的候选路径（有 GEMINI_OAUTH2_JS_PATH/GEMINI_CLI_HOME 则优先） */
export function oauth2JsCandidates(home: string, env: NodeJS.ProcessEnv): string[] {
  const direct = env['GEMINI_OAUTH2_JS_PATH']?.trim()
  const cliHome = env['GEMINI_CLI_HOME']?.trim()
  const fixed = [
    '/opt/homebrew/lib/node_modules/@google/gemini-cli',
    '/usr/local/lib/node_modules/@google/gemini-cli',
    join(home, '.bun/install/global/node_modules/@google/gemini-cli'),
  ]
  const roots: string[] = []
  if (cliHome) roots.push(cliHome)
  try {
    const nvmDir = join(home, '.nvm', 'versions', 'node')
    for (const version of readdirSync(nvmDir)) {
      roots.push(join(nvmDir, version, 'lib', 'node_modules', '@google', 'gemini-cli'))
    }
  } catch {
    // 无 nvm
  }
  roots.push(...fixed)
  const candidates: string[] = []
  if (direct) candidates.push(direct)
  for (const root of roots) {
    candidates.push(join(root, 'dist', 'src', 'code_assist', 'oauth2.js'))
    candidates.push(join(root, 'src', 'code_assist', 'oauth2.js'))
  }
  return candidates
}

export function extractOAuthClient(home: string, env: NodeJS.ProcessEnv): { clientId: string; clientSecret: string } | null {
  const clientId = env['GEMINI_OAUTH_CLIENT_ID']?.trim()
  const clientSecret = env['GEMINI_OAUTH_CLIENT_SECRET']?.trim()
  if (clientId && clientSecret) return { clientId, clientSecret }
  for (const path of oauth2JsCandidates(home, env)) {
    try {
      if (!existsSync(path)) continue
      const content = readFileSync(path, 'utf8')
      const id = content.match(/(?:client_id|CLIENT_ID)['"`]?\s*[:=]\s*['"]([^'"]+)['"]/)?.[1]
      const secret = content.match(/(?:client_secret|CLIENT_SECRET)['"`]?\s*[:=]\s*['"]([^'"]+)['"]/)?.[1]
      if (id && secret) return { clientId: id, clientSecret: secret }
    } catch {
      // 换下一个候选路径
    }
  }
  return null
}

export function readGeminiCreds(home: string, env: NodeJS.ProcessEnv): GeminiCreds | null {
  // settings.json 明确选了 API key 模式 → 没有订阅额度可看
  try {
    const settings = JSON.parse(readFileSync(join(home, '.gemini', 'settings.json'), 'utf8')) as Record<string, any>
    if (settings?.['security']?.['auth']?.['selectedType'] === 'api-key') return null
  } catch {
    // 无 settings.json（老版本默认 oauth-personal）→ 继续
  }
  const credsPath = join(home, '.gemini', 'oauth_creds.json')
  let parsed: Record<string, any>
  try {
    parsed = JSON.parse(readFileSync(credsPath, 'utf8')) as Record<string, any>
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null
  const client = extractOAuthClient(home, env)
  return {
    accessToken: quotaStr(parsed['access_token']),
    refreshToken: quotaStr(parsed['refresh_token']),
    expiryMs: quotaNum(parsed['expiry_date']),
    clientId: client?.clientId ?? null,
    clientSecret: client?.clientSecret ?? null,
    credsPath,
  }
}

/** access_token 过期（< now+60s）时尝试静默刷新并回写 oauth_creds.json；失败返回原值由 API 报 401 */
export async function ensureFreshAccessToken(
  creds: GeminiCreds, doFetch: FetchLike, now: number,
): Promise<string | null> {
  const fresh = creds.accessToken !== null && (creds.expiryMs === null || creds.expiryMs > now + 60_000)
  if (fresh) return creds.accessToken
  if (!creds.refreshToken || !creds.clientId || !creds.clientSecret) return creds.accessToken
  try {
    const res = await doFetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
        refresh_token: creds.refreshToken,
        grant_type: 'refresh_token',
      }).toString(),
      signal: AbortSignal.timeout(15_000),
    })
    if (!res.ok) return creds.accessToken
    const json = (await res.json()) as Record<string, unknown>
    const newToken = quotaStr(json['access_token'])
    if (!newToken) return creds.accessToken
    const expiresIn = quotaNum(json['expires_in'])
    try {
      const updated = JSON.parse(readFileSync(creds.credsPath, 'utf8')) as Record<string, any>
      updated['access_token'] = newToken
      if (expiresIn !== null) updated['expiry_date'] = now + expiresIn * 1000
      if (quotaStr(json['id_token'])) updated['id_token'] = json['id_token']
      writeFileSync(creds.credsPath, JSON.stringify(updated, null, 2))
    } catch {
      // 回写失败不影响本轮读取
    }
    return newToken
  } catch {
    return creds.accessToken
  }
}

type CodeAssistStatus = { tier: string | null; projectId: string | null }

async function loadCodeAssistStatus(token: string, doFetch: FetchLike): Promise<CodeAssistStatus> {
  const { body } = await quotaFetchJson(
    doFetch, 'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ metadata: { ideType: 'GEMINI_CLI', pluginType: 'GEMINI' } }),
    },
  )
  const root = (body ?? {}) as Record<string, any>
  const projectRaw = root['cloudaicompanionProject']
  return {
    tier: quotaStr(root['currentTier']),
    projectId: quotaStr(projectRaw) ?? quotaStr((projectRaw as Record<string, any> | null)?.['id']),
  }
}

/** 兜底项目发现：gen-lang-client* 前缀或带 generative-language 标签的项目 */
async function discoverProjectId(token: string, doFetch: FetchLike): Promise<string | null> {
  try {
    const { body } = await quotaFetchJson(
      doFetch, 'https://cloudresourcemanager.googleapis.com/v1/projects', {
        headers: { authorization: `Bearer ${token}`, accept: 'application/json' },
      },
    )
    const projects = ((body ?? {}) as Record<string, any>)['projects']
    if (!Array.isArray(projects)) return null
    for (const project of projects) {
      const id = quotaStr((project as Record<string, any>)?.['projectId'])
      if (!id) continue
      if (id.startsWith('gen-lang-client')) return id
      const labels = (project as Record<string, any>)?.['labels']
      if (labels && typeof labels === 'object' && 'generative-language' in labels) return id
    }
  } catch {
    // 项目发现是尽力而为
  }
  return null
}

async function retrieveUserQuota(
  token: string, projectId: string | null, doFetch: FetchLike,
): Promise<Array<Record<string, any>>> {
  const body: Record<string, unknown> = projectId ? { project: projectId } : {}
  const res = await quotaFetchJson(
    doFetch, 'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota', {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    },
  )
  const buckets = ((res.body ?? {}) as Record<string, any>)['buckets']
  return Array.isArray(buckets) ? buckets : []
}

export async function fetchGeminiAccount(
  creds: GeminiCreds, doFetch: FetchLike, now: number,
): Promise<QuotaAccount> {
  try {
    const token = await ensureFreshAccessToken(creds, doFetch, now)
    if (!token) throw new Error('oauth_creds.json 缺少 access_token 且无法刷新')

    let status: CodeAssistStatus = { tier: null, projectId: null }
    try {
      status = await loadCodeAssistStatus(token, doFetch)
    } catch {
      // loadCodeAssist 失败不阻塞配额查询
    }
    const projectId = status.projectId ?? await discoverProjectId(token, doFetch)
    const buckets = await retrieveUserQuota(token, projectId, doFetch)
    if (buckets.length === 0) throw new Error('配额响应缺少 buckets 数据')

    // 每个模型取最低 remaining_fraction 的桶（通常 input 侧先到限）
    const perModel = new Map<string, { fraction: number; resetAt: number | null }>()
    for (const raw of buckets) {
      if (raw === null || typeof raw !== 'object') continue
      const bucket = raw as Record<string, unknown>
      const modelId = quotaStr(bucket['model_id'])
      const fraction = quotaNum(bucket['remaining_fraction'])
      if (!modelId || fraction === null) continue
      const existing = perModel.get(modelId)
      if (!existing || fraction < existing.fraction) {
        perModel.set(modelId, { fraction, resetAt: toEpochMs(bucket['reset_time']) })
      }
    }
    const windows: QuotaWindow[] = [...perModel.entries()]
      .map(([modelId, info]) => ({
        key: modelId,
        label: modelId,
        usedPercent: Math.min(100, Math.max(0, (1 - info.fraction) * 100)),
        percentage: Math.min(100, Math.max(0, (1 - info.fraction) * 100)),
        nextResetAt: info.resetAt,
      }))
      .sort((a, b) => (b.percentage ?? 0) - (a.percentage ?? 0))
      .slice(0, 6)

    return finalizeAccount({
      kind: 'gemini', label: LABEL, provider: null,
      planName: status.tier ? TIER_NAMES[status.tier] ?? status.tier : null,
      windows, anySuccess: true, now,
    })
  } catch (err) {
    return finalizeAccount({
      kind: 'gemini', label: LABEL, provider: null,
      error: errText(err), httpStatus: readHttpStatus(err), now,
    })
  }
}

export async function geminiAccount(home: string, env: NodeJS.ProcessEnv, doFetch: FetchLike, now: number): Promise<QuotaAccount> {
  const creds = readGeminiCreds(home, env)
  if (!creds) return missingAccount('gemini', LABEL, now)
  return fetchGeminiAccount(creds, doFetch, now)
}
