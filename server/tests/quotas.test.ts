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
  it('全部无凭据 → 六个账号 no_credentials 且零网络', async () => {
    const { fn, calls } = fakeFetch({})
    const poller = new QuotaPoller({ home: '/nonexistent', env: {}, fetchImpl: fn })
    const snap = await poller.current()
    expect(snap.accounts).toHaveLength(6)
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
