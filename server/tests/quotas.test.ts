// server/tests/quotas.test.ts — 多 provider 订阅额度：凭据解析、响应归一化、
// 隔离降级、QuotaPoller TTL、代理 env 自举。所有网络走注入的 fake fetch，不出网。
// fixtures 取自各平台真实接口/cockpit-tools 源码的响应结构（值脱敏）。
import { createHash, createCipheriv, randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, it, expect, afterEach } from 'vitest'
import {
  extractCodexAccountId, readCodexAuth, fetchCodexAccount,
} from '../src/quotas/codex.js'
import { readClaudeAuth, fetchClaudeAccount } from '../src/quotas/claude.js'
import {
  extractCursorUserId, readCursorAuth, fetchCursorAccount,
} from '../src/quotas/cursor.js'
import { readWorkbuddyAuth, workbuddyWindows } from '../src/quotas/workbuddy.js'
import { readTraeAuth, traeWindows } from '../src/quotas/trae.js'
import { readKimiAuth, fetchKimiAccount } from '../src/quotas/kimi.js'
import { readGrokAuth, fetchGrokAccount, grokAccount } from '../src/quotas/grok.js'
import { fetchCopilotAccount, readCopilotAuth } from '../src/quotas/copilot.js'
import { fetchOpenRouterAccount, readOpenRouterAuth } from '../src/quotas/openrouter.js'
import { readCodebuffAuth, fetchCodebuffAccount } from '../src/quotas/codebuff.js'
import { readFactoryApiKey, fetchFactoryAccount } from '../src/quotas/factory.js'
import { readMiniMaxAuth, fetchMiniMaxAccount } from '../src/quotas/minimax.js'
import { readZedAuth, fetchZedAccount } from '../src/quotas/zed.js'
import { readKiroAuth, kiroEndpointForArn, fetchKiroAccount } from '../src/quotas/kiro.js'
import {
  readGeminiCreds, extractOAuthClient, ensureFreshAccessToken, fetchGeminiAccount,
} from '../src/quotas/gemini.js'
import { QuotaPoller } from '../src/quotas/poller.js'
import { PLAN_TTL_MS } from '../src/plan.js'
import { parseScutilProxy } from '../src/quotas/proxy.js'

function encryptFile(plain: string, secret: string): string {
  const key = createHash('sha256').update(secret).digest()
  const nonce = randomBytes(12)
  const cipher = createCipheriv('aes-256-gcm', key, nonce)
  const enc = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()])
  return `enc:v1:${nonce.toString('base64url')}.${cipher.getAuthTag().toString('base64url')}.${enc.toString('base64url')}`
}

/** 构造一个形状合法的假 JWT（payload=payloadJson 的 base64url） */
function fakeJwt(payload: Record<string, unknown>): string {
  const b64 = (o: unknown): string => Buffer.from(JSON.stringify(o)).toString('base64url')
  return `${b64({ alg: 'RS256' })}.${b64(payload)}.sig`
}

function fakeFetch(routes: Record<string, unknown>) {
  const calls: Array<{ url: string; init: { method?: string; headers?: Record<string, string>; body?: string } }> = []
  const fn = async (url: string, init: { method?: string; headers?: Record<string, string>; body?: string } = {}) => {
    calls.push({ url, init })
    const key = Object.keys(routes).find(k => url.includes(k))
    if (!key) throw new Error('unexpected url ' + url)
    return { ok: true, status: 200, json: async () => routes[key] }
  }
  return { fn, calls }
}

// ---------- codex ----------

const CODEX_OK = {
  user_id: 'user-x', account_id: 'acc-1', plan_type: 'team',
  rate_limit: {
    allowed: true, limit_reached: false,
    primary_window: { used_percent: 16, limit_window_seconds: 18000, reset_after_seconds: 7788, reset_at: 1789372788 },
    secondary_window: { used_percent: 2, limit_window_seconds: 604800, reset_after_seconds: 594588, reset_at: 1789959588 },
  },
  rate_limit_reset_credits: { available_count: 3, applicable_available_count: 0 },
}

describe('codex', () => {
  it('auth.json 解析 + accountId 兜底自 JWT', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.codex'), { recursive: true })
      const token = fakeJwt({ 'https://api.openai.com/auth': { chatgpt_account_id: 'acc-jwt' } })
      await writeFile(join(home, '.codex', 'auth.json'), JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: token, account_id: 'acc-file' } }))
      expect(readCodexAuth(home, {})).toEqual({ token, accountId: 'acc-file' })
      await writeFile(join(home, '.codex', 'auth.json'), JSON.stringify({ tokens: { access_token: token } }))
      expect(readCodexAuth(home, {})!.accountId).toBe('acc-jwt')
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('wham/usage 归一：5 小时窗口 + 周，百分比口径，reset 秒→毫秒，重置卡张数', async () => {
    const { fn, calls } = fakeFetch({ 'wham/usage': CODEX_OK })
    const acc = await fetchCodexAccount({ token: 't', accountId: 'acc-1' }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.planName).toBe('team')
    expect(acc.windows.map(w => w.key)).toEqual(['fiveHour', 'week'])
    expect(acc.windows[0]).toMatchObject({ usedPercent: 16, percentage: 16, nextResetAt: 1789372788000 })
    expect(acc.resetCredits).toBe(3)
    expect(acc.applicableResetCredits).toBe(0)
    expect(calls[0]!.init.headers!['chatgpt-account-id']).toBe('acc-1')
    expect(calls[0]!.init.headers!['authorization']).toBe('Bearer t')
  })
  it('wham/usage 无重置卡字段时 resetCredits 为 null', async () => {
    const noCredits = { ...CODEX_OK } as Record<string, unknown>
    delete noCredits['rate_limit_reset_credits']
    const { fn } = fakeFetch({ 'wham/usage': noCredits })
    const acc = await fetchCodexAccount({ token: 't', accountId: null }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.resetCredits).toBeNull()
    expect(acc.applicableResetCredits).toBeNull()
  })
  it('env 凭据路径 + 无凭据隐藏', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      expect(readCodexAuth(home, { CODEX_ACCESS_TOKEN: ' abc ' })).toEqual({ token: 'abc', accountId: null })
      expect(readCodexAuth(home, {})).toBeNull()
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('extractCodexAccountId：无 auth claim → null', () => {
    expect(extractCodexAccountId(fakeJwt({ sub: 'x' }))).toBeNull()
    expect(extractCodexAccountId('not-a-jwt')).toBeNull()
  })
})

// ---------- claude ----------

const CLAUDE_OK = {
  five_hour: { utilization: 0.42, resets_at: '2026-09-14T16:00:00Z' },
  seven_day: { utilization: 12, resets_at: 1789959588 },
  seven_day_sonnet: { utilization: 3, resets_at: 1789959588 },
}

describe('claude', () => {
  it('credentials.json 的 claudeAiOauth.accessToken；env 优先', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.claude'), { recursive: true })
      await writeFile(join(home, '.claude', '.credentials.json'), JSON.stringify({ claudeAiOauth: { accessToken: 'tok-file' } }))
      expect(readClaudeAuth(home, {})).toEqual({ token: 'tok-file' })
      expect(readClaudeAuth(home, { CLAUDE_ACCESS_TOKEN: 'tok-env' })).toEqual({ token: 'tok-env' })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('usage 归一：utilization 0-1 → 0-100，ISO 与 epoch 重置时间并存', async () => {
    const { fn, calls } = fakeFetch({ '/api/oauth/usage': CLAUDE_OK })
    const acc = await fetchClaudeAccount({ token: 't' }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.windows.map(w => w.key)).toEqual(['fiveHour', 'week', 'weekSonnet'])
    expect(acc.windows[0]).toMatchObject({ usedPercent: 42, percentage: 42 })
    expect(acc.windows[0]!.nextResetAt).toBe(Date.parse('2026-09-14T16:00:00Z'))
    expect(acc.windows[1]!.nextResetAt).toBe(1789959588000)
    expect(calls[0]!.init.headers!['anthropic-beta']).toBe('oauth-2025-04-20')
  })
})

// ---------- cursor ----------

const CURSOR_OK = {
  startOfMonth: '2026-09-01T00:00:00.000Z',
  membershipType: 'pro',
  prompts: { secondary: { usedPercentage: 33.3, maxPercentage: 100, resetDate: '2026-10-01T00:00:00.000Z' } },
}

describe('cursor', () => {
  it('WorkOS cookie 取自 JWT sub', async () => {
    const token = fakeJwt({ sub: 'user_abc' })
    const { fn, calls } = fakeFetch({ 'usage-summary': CURSOR_OK })
    const acc = await fetchCursorAccount({ token }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.planName).toBe('pro')
    expect(acc.windows[0]).toMatchObject({ key: 'cycle', usedPercent: 33.3 })
    expect(calls[0]!.init.headers!.cookie).toBe(`WorkosCursorSessionToken=user_abc%3A%3A${token}`)
  })
  it('非 JWT token → 明确报错不崩；env 凭据读取', async () => {
    const { fn } = fakeFetch({})
    const acc = await fetchCursorAccount({ token: 'plain' }, fn, 1000)
    expect(acc.available).toBe(false)
    expect(acc.error).toContain('JWT')
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.cursor'), { recursive: true })
      await writeFile(join(home, '.cursor', 'auth.json'), JSON.stringify({ accessToken: 'tok' }))
      expect(readCursorAuth(home, {})).toEqual({ token: 'tok' })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
})

// ---------- workbuddy ----------

const WORKBUDDY_RESOURCE = {
  code: 0,
  data: { Response: { Data: { Accounts: [{
    CycleCapacitySize: 1000, CycleCapacityUsed: 250, CycleCapacityRemain: 750,
    CapacityUnit: 'credits', CycleEndTime: '2026-10-01 00:00:00', Unlimited: false,
  }] } } },
}

describe('workbuddy', () => {
  it('腾讯云资源包 → 周期窗口（总额/已用/剩余/重置）', () => {
    const ws = workbuddyWindows(WORKBUDDY_RESOURCE)
    expect(ws).toHaveLength(1)
    expect(ws[0]).toMatchObject({ key: 'cycle', total: 1000, used: 250, remaining: 750, percentage: 25, nextResetAt: Date.parse('2026-10-01T00:00:00') })
  })
  it('凭据文件（~/codeburn-agg/workbuddy-auth.json）与 env 两条路', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, 'codeburn-agg'), { recursive: true })
      await writeFile(join(home, 'codeburn-agg', 'workbuddy-auth.json'), JSON.stringify({ accessToken: 'tok', uid: 'u1', enterpriseId: 'e1' }))
      expect(readWorkbuddyAuth(home, {})).toEqual({ token: 'tok', uid: 'u1', enterpriseId: 'e1', domain: null })
      expect(readWorkbuddyAuth(home, { WORKBUDDY_ACCESS_TOKEN: 'env-tok' })).toEqual({ token: 'env-tok', uid: null, enterpriseId: null, domain: null })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
})

// ---------- trae ----------

const TRAE_USAGE = {
  code: 0,
  user_entitlement_pack_list: [
    { product_type: 3, product_name: '其它包', entitlement_base_info: { end_time: 1789959588 } },
    { product_type: 6, product_name: 'Pro 包', entitlement_used: 120, entitlement_total: 500, entitlement_base_info: { end_time: 1789959588 } },
  ],
}

describe('trae', () => {
  it('按 product_type 优先级取主包（6 先于 3），窗口含已用/总额/重置', () => {
    const { windows, planName } = traeWindows(TRAE_USAGE)
    expect(planName).toBe('Pro 包')
    expect(windows).toHaveLength(1)
    expect(windows[0]).toMatchObject({ key: 'cycle', total: 500, used: 120, remaining: null, percentage: 24, nextResetAt: 1789959588000 })
  })
  it('凭据：env（默认 intl）与文件（region=cn）', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, 'codeburn-agg'), { recursive: true })
      await writeFile(join(home, 'codeburn-agg', 'trae-auth.json'), JSON.stringify({ accessToken: 'tok', region: 'cn' }))
      expect(readTraeAuth(home, {})).toEqual({ token: 'tok', region: 'cn' })
      expect(readTraeAuth(home, { TRAE_ACCESS_TOKEN: 'env' })).toEqual({ token: 'env', region: 'intl' })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
})

// ---------- kimi ----------

const KIMI_CODE_OK = {
  usage: { limit: '7000', used: '1680', remaining: '5320', resetTime: '2026-09-15T00:00:00Z' },
  limits: [{ window: { duration: 5, timeUnit: 'TIME_UNIT_HOUR' }, detail: { limit: '200', used: '50', remaining: '150', reset_at: 1789959588 } }],
  user: { membership: { level: 'LEVEL_BASIC' } },
}

describe('kimi', () => {
  it('凭据：env KIMI_CODE_API_KEY；文件 access_token 须未过期（> now+60s）', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.kimi-code', 'credentials'), { recursive: true })
      const future = Math.floor(Date.now() / 1000) + 3600
      const past = Math.floor(Date.now() / 1000) - 3600
      await writeFile(join(home, '.kimi-code', 'credentials', 'kimi-code.json'), JSON.stringify({ access_token: 'tok', refresh_token: 'r', expires_at: future }))
      expect(readKimiAuth(home, {})).toMatchObject({ token: 'tok' })
      await writeFile(join(home, '.kimi-code', 'credentials', 'kimi-code.json'), JSON.stringify({ access_token: 'tok', expires_at: past }))
      expect(readKimiAuth(home, {})).toBeNull()
      expect(readKimiAuth(home, { KIMI_CODE_API_KEY: ' env ' })).toEqual({ token: 'env', baseUrl: 'https://api.kimi.com' })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('usages 归一：周额度绝对值 + 速率窗口；LEVEL_BASIC → Moderato', async () => {
    const { fn, calls } = fakeFetch({ 'coding/v1/usages': KIMI_CODE_OK })
    const acc = await fetchKimiAccount({ token: 't', baseUrl: 'https://api.kimi.com' }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.planName).toBe('Moderato')
    expect(acc.windows[0]).toMatchObject({ key: 'week', total: 7000, used: 1680, remaining: 5320, percentage: 24, nextResetAt: Date.parse('2026-09-15T00:00:00Z') })
    expect(acc.windows[1]).toMatchObject({ key: 'rate', total: 200, used: 50 })
    expect(calls[0]!.init.headers!['x-msh-platform']).toBe('kimi_code_cli')
    expect(calls[0]!.init.headers!['authorization']).toBe('Bearer t')
  })
})

// ---------- grok ----------

const GROK_OK = {
  config: {
    creditUsagePercent: 41.5,
    currentPeriod: { end: '2026-10-01T00:00:00Z' },
    onDemandCap: { val: 100 }, onDemandUsed: { val: 10 },
    subscriptionTier: 'supergrok_heavy',
  },
}

describe('grok', () => {
  it('auth.json：优先 SuperGrok OIDC scope；expires_at 过期标记', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.grok'), { recursive: true })
      await writeFile(join(home, '.grok', 'auth.json'), JSON.stringify({
        'https://accounts.x.ai/sign-in': { key: 'legacy-tok' },
        'https://auth.x.ai::oidc': { key: 'oidc-tok' },
      }))
      expect(readGrokAuth(home, {})).toEqual({ token: 'oidc-tok', expired: false })
      const stale = new Date(Date.now() - 3600_000).toISOString()
      await writeFile(join(home, '.grok', 'auth.json'), JSON.stringify({ 'https://auth.x.ai::oidc': { key: 'oidc-tok', expires_at: stale } }))
      expect(readGrokAuth(home, {})).toMatchObject({ expired: true })
      expect(readGrokAuth(home, { GROK_OAUTH_TOKEN: ' env ' })).toEqual({ token: 'env', expired: false })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('billing?format=credits：creditUsagePercent + 周期重置；supergrok_heavy → SuperGrok Heavy', async () => {
    const { fn, calls } = fakeFetch({ 'v1/billing': GROK_OK })
    const acc = await fetchGrokAccount({ token: 't', expired: false }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.planName).toBe('SuperGrok Heavy')
    expect(acc.windows[0]).toMatchObject({ key: 'cycle', usedPercent: 41.5, nextResetAt: Date.parse('2026-10-01T00:00:00Z') })
    expect(calls[0]!.init.headers!['x-xai-token-auth']).toBe('xai-grok-cli')
    expect(calls[0]!.url).toContain('format=credits')
  })
  it('过期凭据 → error 账号且零网络', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.grok'), { recursive: true })
      const stale = new Date(Date.now() - 3600_000).toISOString()
      await writeFile(join(home, '.grok', 'auth.json'), JSON.stringify({ 'https://auth.x.ai::oidc': { key: 't', expires_at: stale } }))
      const { fn, calls } = fakeFetch({})
      const acc = await grokAccount(home, {}, fn, Date.now())
      expect(acc.available).toBe(false)
      expect(acc.error).toContain('过期')
      expect(calls).toHaveLength(0)
    } finally { await rm(home, { recursive: true, force: true }) }
  })
})

// ---------- copilot ----------

const COPILOT_OK = {
  copilot_plan: 'individual',
  quota_reset_date: '2026-10-01',
  quota_snapshots: {
    premium_interactions: { entitlement: 300, remaining: 210, percent_remaining: 70 },
    chat: { unlimited: true },
  },
}

describe('copilot', () => {
  it('quota_snapshots：premium 百分比换算、unlimited 丢弃；Copilot 伪装头', async () => {
    const { fn, calls } = fakeFetch({ 'copilot_internal/user': COPILOT_OK })
    const acc = await fetchCopilotAccount('gh-tok', fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.planName).toBe('individual')
    expect(acc.windows.map(w => w.key)).toEqual(['premium'])
    expect(acc.windows[0]).toMatchObject({ total: 300, remaining: 210, usedPercent: 30, nextResetAt: Date.parse('2026-10-01') })
    expect(calls[0]!.init.headers!.authorization).toBe('token gh-tok')
    expect(calls[0]!.init.headers!['editor-version']).toBe('vscode/1.96.2')
    expect(readCopilotAuth({ COPILOT_API_TOKEN: ' t ' })).toBe('t')
  })
})

// ---------- openrouter ----------

describe('openrouter', () => {
  it('credits → 余额窗口；/key 限额失败不影响主快照', async () => {
    const { fn, calls } = fakeFetch({
      '/credits': { data: { total_credits: 100, total_usage: 37 } },
      '/key': { data: { limit: 50, limit_remaining: 20, usage: 30, limit_reset: 'monthly' } },
    })
    const acc = await fetchOpenRouterAccount({ token: 't', baseUrl: 'https://openrouter.ai/api/v1' }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.windows[0]).toMatchObject({ key: 'credits', total: 100, used: 37, remaining: 63, percentage: 37 })
    expect(acc.windows[1]).toMatchObject({ key: 'limit', total: 50, used: 30, remaining: 20 })
    expect(calls[0]!.init.headers!.authorization).toBe('Bearer t')
  })
  it('env 缺失 → no_credentials；API_URL 可覆盖', () => {
    expect(readOpenRouterAuth({})).toBeNull()
    expect(readOpenRouterAuth({ OPENROUTER_API_KEY: 'k', OPENROUTER_API_URL: 'https://proxy.example/v1/' }))
      .toEqual({ token: 'k', baseUrl: 'https://proxy.example/v1' })
  })
})

// ---------- codebuff ----------

describe('codebuff', () => {
  it('凭据：env；credentials.json 兼容 authToken 与 default.authToken', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.config', 'manicode'), { recursive: true })
      await writeFile(join(home, '.config', 'manicode', 'credentials.json'), JSON.stringify({ default: { authToken: 'nested' } }))
      expect(readCodebuffAuth(home, {})).toMatchObject({ token: 'nested' })
      await writeFile(join(home, '.config', 'manicode', 'credentials.json'), JSON.stringify({ authToken: 'flat' }))
      expect(readCodebuffAuth(home, {})).toMatchObject({ token: 'flat' })
      expect(readCodebuffAuth(home, { CODEBUFF_API_KEY: 'env' })).toMatchObject({ token: 'env' })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('usage 是 POST + Bearer；usage/quota → 积分窗口，subscription.rateLimit → 周窗口', async () => {
    const { fn, calls } = fakeFetch({
      '/api/v1/usage': { usage: 120, quota: 1000, remainingBalance: 880, next_quota_reset: '2026-10-01T00:00:00Z' },
      '/api/user/subscription': { subscription: { displayName: 'Pro', status: 'active' }, rateLimit: { weeklyUsed: 40, weeklyLimit: 200, weeklyResetsAt: 1789959588 } },
    })
    const acc = await fetchCodebuffAccount({ token: 't', baseUrl: 'https://www.codebuff.com' }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.planName).toBe('Pro')
    expect(acc.windows[0]).toMatchObject({ key: 'credits', total: 1000, used: 120, remaining: 880, percentage: 12, nextResetAt: Date.parse('2026-10-01T00:00:00Z') })
    expect(acc.windows[1]).toMatchObject({ key: 'week', total: 200, used: 40, percentage: 20, nextResetAt: 1789959588000 })
    expect(calls[0]!.init.method).toBe('POST')
    expect(calls[0]!.init.headers!.authorization).toBe('Bearer t')
  })
})

// ---------- factory ----------

const FACTORY_LIMITS = {
  usesTokenRateLimitsBilling: true,
  limits: {
    standard: {
      fiveHour: { usedPercent: 22, secondsRemaining: 3600 },
      weekly: { usedPercent: 10, windowEnd: '2026-09-21T00:00:00Z' },
      monthly: { usedPercent: 5, windowEnd: 1789959588 },
    },
    core: null,
  },
  extraUsageBalanceCents: 0,
}

describe('factory', () => {
  it('凭据：env；~/.factory/.env 支持 export 前缀与引号', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.factory'), { recursive: true })
      await writeFile(join(home, '.factory', '.env'), '# comment\nexport FACTORY_API_KEY="fk-file"\nOTHER=1\n')
      expect(readFactoryApiKey(home, {})).toBe('fk-file')
      expect(readFactoryApiKey(home, { FACTORY_API_KEY: 'fk-env' })).toBe('fk-env')
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('billing/limits：5h/周/月三窗口；secondsRemaining 优先；过期 windowEnd 视为 0%', async () => {
    const now = Date.parse('2026-09-14T12:00:00Z')
    const { fn, calls } = fakeFetch({ '/api/billing/limits': FACTORY_LIMITS })
    const acc = await fetchFactoryAccount('fk', fn, now)
    expect(acc.available).toBe(true)
    expect(acc.windows[0]).toMatchObject({ key: 'fiveHour', usedPercent: 22, nextResetAt: now + 3600_000 })
    expect(acc.windows[1]).toMatchObject({ key: 'week', usedPercent: 10, nextResetAt: Date.parse('2026-09-21T00:00:00Z') })
    expect(acc.windows[2]).toMatchObject({ key: 'cycle', usedPercent: 5, nextResetAt: 1789959588000 })
    expect(calls[0]!.url).toContain('https://api.factory.ai')
    // 过期窗口：windowEnd 在过去且无 secondsRemaining → 0%
    const expired = { limits: { standard: { fiveHour: { usedPercent: 99, windowEnd: '2020-01-01T00:00:00Z' }, weekly: { usedPercent: 1 }, monthly: { usedPercent: 1 } } } }
    const { fn: fn2 } = fakeFetch({ '/api/billing/limits': expired })
    const acc2 = await fetchFactoryAccount('fk', fn2, now)
    expect(acc2.windows[0]!.usedPercent).toBe(0)
  })
})

// ---------- minimax ----------

const MINIMAX_OK = {
  data: {
    base_resp: { status_code: 0 },
    model_remains: [{
      model_name: 'abab-mini',
      current_interval_total_count: 500, current_interval_usage_count: 400,
      current_interval_remaining_percent: 20, end_time: 1789372788,
      current_weekly_total_count: 2000, current_weekly_usage_count: 1000, weekly_end_time: 1789959588,
    }],
  },
}

describe('minimax', () => {
  it('usage_count 是剩余量：used = total - remaining；remaining_percent 兜底', async () => {
    const { fn, calls } = fakeFetch({ 'token_plan/remains': MINIMAX_OK })
    const acc = await fetchMiniMaxAccount({ token: 't', regions: [{ apiBase: 'https://api.minimax.io' }] }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.windows[0]).toMatchObject({ key: 'fiveHour', total: 500, used: 100, remaining: 400, percentage: 20, nextResetAt: 1789372788000 })
    expect(acc.windows[1]).toMatchObject({ key: 'week', total: 2000, used: 1000, percentage: 50 })
    expect(calls[0]!.init.headers!['mm-api-source']).toBe('wattson-usage')
  })
  it('国际端点失败 → 回退中国端点；MINIMAX_REGION=cn 调换顺序', async () => {
    const calls: string[] = []
    const fn = async (url: string) => {
      calls.push(url)
      if (url.includes('minimax.io')) throw Object.assign(new Error('HTTP 502'), { quotaHttpStatus: 502 })
      return { ok: true, status: 200, json: async () => MINIMAX_OK }
    }
    const acc = await fetchMiniMaxAccount({ token: 't', regions: [{ apiBase: 'https://api.minimax.io' }, { apiBase: 'https://api.minimaxi.com' }] }, fn, 1000)
    expect(acc.available).toBe(true)
    expect(calls[0]).toContain('minimax.io')
    // 国际区两条路径都失败后，才切到中国区
    expect(calls[1]).toContain('minimax.io/v1/api/openplatform')
    expect(calls[2]).toContain('minimaxi.com')
    expect(readMiniMaxAuth({ MINIMAX_API_KEY: 'k', MINIMAX_REGION: 'cn' })!.regions[0]!.apiBase).toBe('https://api.minimaxi.com')
  })
})

// ---------- zed ----------

const ZED_OK = {
  user: { id: 42, github_login: 'octocat' },
  plan: {
    plan_v3: 'zed_pro',
    subscription_period: { started_at: '2026-09-01T00:00:00Z', ended_at: '2026-10-01T00:00:00Z' },
    usage: { edit_predictions: { used: 300, limit: 1000 } },
  },
}

describe('zed', () => {
  it('env 凭据须 token+userId 成对；默认不读钥匙串', async () => {
    expect(await readZedAuth({ ZED_ACCESS_TOKEN: 't' })).toBeNull()
    expect(await readZedAuth({ ZED_ACCESS_TOKEN: 't', ZED_USER_ID: '42' })).toEqual({ userId: '42', token: 't' })
    expect(await readZedAuth({}, { findInternet: true } as never)).toBeNull()
  })
  it('users/me：edit_predictions 窗口 + 账期进度；Authorization 为 "<uid> <tok>"', async () => {
    const now = Date.parse('2026-09-15T00:00:00Z')
    const { fn, calls } = fakeFetch({ 'client/users/me': ZED_OK })
    const acc = await fetchZedAccount({ userId: '42', token: 't' }, fn, now)
    expect(acc.available).toBe(true)
    expect(acc.planName).toBe('zed_pro')
    expect(acc.windows[0]).toMatchObject({ key: 'editPredictions', total: 1000, used: 300, remaining: 700, percentage: 30, nextResetAt: Date.parse('2026-10-01T00:00:00Z') })
    // 账期 14/30 天 → ~46.7%
    expect(acc.windows[1]!.key).toBe('cycle')
    expect(acc.windows[1]!.percentage).toBeCloseTo(46.7, 0)
    expect(calls[0]!.init.headers!.authorization).toBe('42 t')
  })
})

// ---------- kiro ----------

const KIRO_OK = {
  usageBreakdownList: [{
    resourceType: 'CREDIT',
    usageLimitWithPrecision: 100,
    currentUsageWithPrecision: 45.5,
    currentOveragesWithPrecision: 5.5,
    nextDateReset: 1789959588,
  }],
}

describe('kiro', () => {
  it('凭据：env 优先；kiro-cli SQLite 经注入的 sqlite3 读取', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      const dataDir = join(home, 'kiro-cli-data')
      await mkdir(dataDir, { recursive: true })
      await writeFile(join(dataDir, 'data.sqlite3'), 'not-a-real-db')
      const run = async (_file: string, args: string[]) => {
        const sql = args[2] ?? args.at(-1) ?? ''
        if (sql.includes('auth_kv')) return { stdout: JSON.stringify([{ value: JSON.stringify({ access_token: 'tok' }) }]), stderr: '' }
        return { stdout: JSON.stringify([{ value: JSON.stringify({ arn: 'arn:aws:codewhisperer:us-east-1:123:profile/default' }) }]), stderr: '' }
      }
      expect(await readKiroAuth(home, { KIRO_DATA_DIR: dataDir }, run)).toEqual({
        accessToken: 'tok',
        profileArn: 'arn:aws:codewhisperer:us-east-1:123:profile/default',
      })
      expect(await readKiroAuth(home, { KIRO_ACCESS_TOKEN: 'e', KIRO_PROFILE_ARN: 'arn' }, run)).toEqual({ accessToken: 'e', profileArn: 'arn' })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('ARN → 端点映射；CREDIT 条目扣除 overage；nextDateReset 秒 → 毫秒', async () => {
    expect(kiroEndpointForArn('arn:aws:codewhisperer:us-east-1:123:profile/default')).toBe('https://codewhisperer.us-east-1.amazonaws.com/')
    expect(kiroEndpointForArn('arn:aws:codewhisperer:eu-central-1:123:profile/default')).toBe('https://q.eu-central-1.amazonaws.com/')
    expect(kiroEndpointForArn('arn:aws:s3:::bucket')).toBeNull()
    const { fn, calls } = fakeFetch({ 'amazonaws.com': KIRO_OK })
    const acc = await fetchKiroAccount({ accessToken: 't', profileArn: 'arn:aws:codewhisperer:us-east-1:123:profile/default' }, fn, 1000)
    expect(acc.available).toBe(true)
    // planUsed = 45.5 - 5.5 = 40
    expect(acc.windows[0]).toMatchObject({ key: 'cycle', total: 100, used: 40, remaining: 60, percentage: 40, nextResetAt: 1789959588000 })
    expect(calls[0]!.init.headers!['x-amz-target']).toBe('AmazonCodeWhispererService.GetUsageLimits')
    expect(JSON.parse(calls[0]!.init.body!)).toEqual({ profileArn: 'arn:aws:codewhisperer:us-east-1:123:profile/default' })
  })
})

// ---------- gemini ----------

describe('gemini', () => {
  it('settings.json api-key 模式 → 无凭据；oauth_creds.json 解析；client 从 env 直取', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.gemini'), { recursive: true })
      await writeFile(join(home, '.gemini', 'settings.json'), JSON.stringify({ security: { auth: { selectedType: 'api-key' } } }))
      await writeFile(join(home, '.gemini', 'oauth_creds.json'), JSON.stringify({ access_token: 't' }))
      expect(readGeminiCreds(home, {})).toBeNull()
      await writeFile(join(home, '.gemini', 'settings.json'), JSON.stringify({ security: { auth: { selectedType: 'oauth-personal' } } }))
      const creds = readGeminiCreds(home, {
        GEMINI_OAUTH_CLIENT_ID: 'cid', GEMINI_OAUTH_CLIENT_SECRET: 'csec',
      })
      expect(creds).toMatchObject({ accessToken: 't', clientId: 'cid', clientSecret: 'csec' })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('OAuth client 可从 GEMINI_OAUTH2_JS_PATH 指向的 gemini-cli 源码抽取', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      const js = join(home, 'oauth2.js')
      await writeFile(js, 'export const CLIENT_ID = "cid-from-file"\nexport const CLIENT_SECRET = "csec-from-file"\n')
      expect(extractOAuthClient(home, { GEMINI_OAUTH2_JS_PATH: js })).toEqual({ clientId: 'cid-from-file', clientSecret: 'csec-from-file' })
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('access_token 过期 → 用 refresh_token 静默刷新并回写 oauth_creds.json', async () => {
    const home = await mkdtemp(join(tmpdir(), 'qx-'))
    try {
      await mkdir(join(home, '.gemini'), { recursive: true })
      const credsPath = join(home, '.gemini', 'oauth_creds.json')
      await writeFile(credsPath, JSON.stringify({ access_token: 'stale', refresh_token: 'r', expiry_date: 1000 }))
      const { fn, calls } = fakeFetch({ 'oauth2.googleapis.com': { access_token: 'fresh', expires_in: 3600 } })
      const creds = { accessToken: 'stale', refreshToken: 'r', expiryMs: 1000, clientId: 'cid', clientSecret: 'csec', credsPath }
      expect(await ensureFreshAccessToken(creds, fn, 1_000_000)).toBe('fresh')
      expect(calls[0]!.init.headers!['content-type']).toBe('application/x-www-form-urlencoded')
      const written = JSON.parse(await import('node:fs/promises').then(fs => fs.readFile(credsPath, 'utf8')))
      expect(written.access_token).toBe('fresh')
      expect(written.expiry_date).toBe(1_000_000 + 3600_000)
    } finally { await rm(home, { recursive: true, force: true }) }
  })
  it('loadCodeAssist → retrieveUserQuota：每模型取最低 remaining_fraction；tier → 套餐名', async () => {
    const { fn, calls } = fakeFetch({
      'loadCodeAssist': { currentTier: 'standard-tier', cloudaicompanionProject: 'gen-lang-client-001' },
      'retrieveUserQuota': {
        buckets: [
          { model_id: 'gemini-2.5-pro', remaining_fraction: 0.9, reset_time: '2026-09-15T00:00:00Z', token_type: 'INPUT' },
          { model_id: 'gemini-2.5-pro', remaining_fraction: 0.5, reset_time: '2026-09-15T00:00:00Z', token_type: 'OUTPUT' },
          { model_id: 'gemini-2.5-flash', remaining_fraction: 0.7, reset_time: '2026-09-15T00:00:00Z', token_type: 'INPUT' },
        ],
      },
    })
    const creds = { accessToken: 't', refreshToken: null, expiryMs: null, clientId: null, clientSecret: null, credsPath: '/x' }
    const acc = await fetchGeminiAccount(creds, fn, 1000)
    expect(acc.available).toBe(true)
    expect(acc.planName).toBe('Standard')
    expect(acc.windows.map(w => w.key)).toEqual(['gemini-2.5-pro', 'gemini-2.5-flash'])
    expect(acc.windows[0]).toMatchObject({ usedPercent: 50, percentage: 50 })
    expect(acc.windows[1]!.usedPercent).toBeCloseTo(30, 6)
    const quotaCall = calls.find(c => c.url.includes('retrieveUserQuota'))
    expect(JSON.parse(quotaCall!.init.body!)).toEqual({ project: 'gen-lang-client-001' })
  })
})

// ---------- QuotaPoller ----------

describe('QuotaPoller', () => {
  it('多 provider 隔离：glm 成功不影响 codex 失败，各账号快照独立', async () => {
    let t = 1000
    const routes = {
      'subscription/list': { code: 200, data: [] },
      'quota/limit': { code: 200, data: { level: 'pro', limits: [{ unit: 3, number: 5, usage: 100, currentValue: 10, remaining: 90, percentage: 10, nextResetTime: 2000 }] } },
    }
    const { fn, calls } = fakeFetch(routes)
    const poller = new QuotaPoller({
      home: '/nonexistent',
      env: { ZCODE_BIGMODEL_USAGE_API_KEY: 'glmkey00000000.abcdef000000', CODEX_ACCESS_TOKEN: 'codextoken' },
      fetchImpl: fn, now: () => t,
    })
    const snap = await poller.current()
    const by = Object.fromEntries(snap.accounts.map(a => [a.kind, a]))
    expect(by['glm']!.available).toBe(true)
    expect(by['glm']!.windows[0]).toMatchObject({ total: 100, used: 10, percentage: 10 })
    expect(by['codex']!.available).toBe(false)
    // fakeFetch 对 wham/usage 抛的是无 HTTP 状态码的普通错误 → 归类为 error（而非 http_error）
    expect(by['codex']!.unavailableReason).toBe('error')
    expect(by['claude']!.unavailableReason).toBe('no_credentials')
    expect(by['trae']!.unavailableReason).toBe('no_credentials')
    // TTL 内不重拉
    await poller.current()
    const n = calls.length
    t += PLAN_TTL_MS + 1
    await poller.current()
    expect(calls.length).toBeGreaterThan(n)
  })
  it('全部无凭据 → 16 个账号 no_credentials 且零网络', async () => {
    const { fn, calls } = fakeFetch({})
    const poller = new QuotaPoller({ home: '/nonexistent', env: {}, fetchImpl: fn })
    const snap = await poller.current()
    expect(snap.accounts).toHaveLength(16)
    expect(snap.accounts.every(a => a.unavailableReason === 'no_credentials')).toBe(true)
    expect(calls).toHaveLength(0)
  })
})

// ---------- 代理 ----------

describe('proxy', () => {
  it('scutil 输出解析', () => {
    const out = [
      '  HTTPEnable : 1', '  HTTPPort : 7897', '  HTTPProxy : 127.0.0.1',
      '  HTTPSEnable : 1', '  HTTPSPort : 7897', '  HTTPSProxy : 127.0.0.1',
      '  SOCKSEnable : 0',
    ].join('\n')
    const p = parseScutilProxy(out)
    expect(p.httpsProxy).toBe('http://127.0.0.1:7897')
    expect(p.httpProxy).toBe('http://127.0.0.1:7897')
  })
  it('显式 env 优先；其次系统代理；都没有直连', async () => {
    const { resolveProxyUrl, createQuotaFetch } = await import('../src/quotas/proxy.js')
    expect(resolveProxyUrl({ env: { HTTPS_PROXY: 'http://x:1' }, platform: 'darwin', scutil: () => '' })).toBe('http://x:1')
    expect(resolveProxyUrl({
      env: {}, platform: 'darwin',
      scutil: () => 'HTTPSEnable : 1\nHTTPSProxy : 127.0.0.1\nHTTPSPort : 7897',
    })).toBe('http://127.0.0.1:7897')
    expect(resolveProxyUrl({ env: {}, platform: 'darwin', scutil: () => 'HTTPSEnable : 0' })).toBeNull()
    expect(resolveProxyUrl({ env: {}, platform: 'linux', scutil: () => '' })).toBeNull()
    // 无代理 → 直连 fetch（不引入 undici）
    const direct = await createQuotaFetch({ env: {}, platform: 'darwin', scutil: () => 'HTTPSEnable : 0' })
    expect(direct.proxyUrl).toBeNull()
  })
})
