// server/tests/plan.test.ts — 订阅额度模块：解密回环、响应归一化、错误降级、TTL 轮询。
// 所有网络走注入的 fake fetch，不出网；fixtures 取自真实接口的响应结构（值脱敏）。
import { createHash, createCipheriv, randomBytes } from 'node:crypto'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { tmpdir, userInfo } from 'node:os'
import { join } from 'node:path'
import { describe, it, expect, afterEach } from 'vitest'
import {
  credentialSecret, decryptCredential, normalizeApiKey,
  parsePlanWindows, parseSubscription, fetchPlanSnapshot,
  readCodingPlanAuth,
} from '../src/plan.js'

/** 与生产 readCodingPlanAuth 完全同口径的密钥构造（平台/用户名取真实值） */
function secretForHome(home: string): string {
  return credentialSecret(home, 'darwin', userInfo().username, {})
}

/** 测试侧加密器（与 zcode CLI enc:v1 方案一致），用于构造凭据 fixture */
function encryptForTest(plain: string, secret: string): string {
  const key = createHash('sha256').update(secret).digest()
  const nonce = randomBytes(12)
  const cipher = createCipheriv('aes-256-gcm', key, nonce)
  const enc = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()])
  const tag = cipher.getAuthTag()
  return `enc:v1:${nonce.toString('base64url')}.${tag.toString('base64url')}.${enc.toString('base64url')}`
}

const HOME = '/Users/tester'
const SECRET = credentialSecret(HOME, 'darwin', HOME, {})
const ENV = {}

describe('凭据解密', () => {
  it('enc:v1 加解密回环', () => {
    const secret = 'unit-test-secret'
    const enc = encryptForTest('2255beabcdef1234.nDOl00000000', secret)
    expect(decryptCredential(enc, secret)).toBe('2255beabcdef1234.nDOl00000000')
  })
  it('密钥不对/格式坏 → null（不抛出）', () => {
    const enc = encryptForTest('some.key-value', 'right-secret')
    expect(decryptCredential(enc, 'wrong-secret')).toBeNull()
    expect(decryptCredential('enc:v1:garbage', SECRET)).toBeNull()
    expect(decryptCredential('plain-value', SECRET)).toBe('plain-value')
  })
  it('api-key 头归一化：剥 Bearer、取 id.secret 形态', () => {
    expect(normalizeApiKey('Bearer 2255beabcdef1234.nDOl00000000')).toBe('2255beabcdef1234.nDOl00000000')
    expect(normalizeApiKey('junk-prefix 2255beabcdef1234.nDOl00000000 suffix')).toBe('2255beabcdef1234.nDOl00000000')
    expect(normalizeApiKey('short.k')).toBe('short.k') // 不匹配宽格式时按原文
  })
})

describe('readCodingPlanAuth', () => {
  const dir = HOME
  it('从 credentials.json 解密出 individual-coding-plan 的 key（bigmodel → bigmodel.cn）', async () => {
    const home = await mkdtemp(join(tmpdir(), 'plan-home-'))
    try {
      const v2 = join(home, '.zcode/v2')
      await mkdir(v2, { recursive: true })
      const secret = secretForHome(home)
      const entry = 'account-provider:coding-plan:account:bigmodel-individual-coding-plan:account:77431772783280681:api-key'
      const teamEntry = 'account-provider:coding-plan:account:bigmodel-team-coding-plan:account:77431772783280681:api-key'
      await writeFile(join(v2, 'credentials.json'), JSON.stringify({
        [teamEntry]: encryptForTest('teamkey00000000.deadbeef0000', secret),
        [entry]: encryptForTest('2255beabcdef1234.nDOl00000000', secret),
        'zcodejwttoken': encryptForTest('not-a-key', secret),
      }))
      const auth = readCodingPlanAuth(home, {})
      expect(auth).not.toBeNull()
      expect(auth!.provider).toBe('bigmodel-individual-coding-plan')
      expect(auth!.host).toBe('https://bigmodel.cn')
      expect(auth!.authorization).toBe('2255beabcdef1234.nDOl00000000')
    } finally {
      await rm(home, { recursive: true, force: true })
    }
  })
  it('zai 家族 provider → zcode.z.ai', async () => {
    const home = await mkdtemp(join(tmpdir(), 'plan-home-'))
    try {
      const v2 = join(home, '.zcode/v2')
      await mkdir(v2, { recursive: true })
      const secret = secretForHome(home)
      const entry = 'account-provider:coding-plan:account:zai-individual-coding-plan:account:1:api-key'
      await writeFile(join(v2, 'credentials.json'), JSON.stringify({ [entry]: encryptForTest('zaikey00000000.cafe00000000', secret) }))
      expect(readCodingPlanAuth(home, {})!.host).toBe('https://zcode.z.ai')
    } finally {
      await rm(home, { recursive: true, force: true })
    }
  })
  it('凭据文件缺失 → null；env 显式 key 优先', async () => {
    expect(readCodingPlanAuth(await mkdtemp(join(tmpdir(), 'plan-empty-')), {})).toBeNull()
    const auth = readCodingPlanAuth(HOME, { ZCODE_BIGMODEL_USAGE_API_KEY: 'envkey00000000.abcdef000000' })
    expect(auth!.provider).toBe('env:bigmodel-usage')
    expect(auth!.authorization).toBe('envkey00000000.abcdef000000')
  })
})

// 以下 fixtures 的结构与 2026-09 真实接口一致（数值为样例）
const QUOTA_OK = {
  code: 200, msg: '操作成功', success: true,
  data: {
    level: 'pro',
    limits: [
      { type: 'CREDIT_LIMIT', unit: 3, number: 5, usage: 12000, currentValue: 734, remaining: 11265, percentage: 6, nextResetTime: 1789369217511 },
      { type: 'CREDIT_LIMIT', unit: 6, number: 1, usage: 60000, currentValue: 22702, remaining: 37297, percentage: 37, nextResetTime: 1789526193988 },
    ],
  },
}
const SUB_OK = {
  code: 200, msg: '操作成功', success: true,
  data: [{
    id: '907377', productId: 'product-f176ba', productName: 'GLM Coding Pro', status: 'VALID',
    valid: '2026-12-09 10:00:00-2027-03-09 10:00:00', autoRenew: 0,
    billingCycle: 'quarterly', nextRenewTime: '2026-12-09', inCurrentPeriod: true,
  }],
}

function fakeFetch(routes: Record<string, unknown | Error>) {
  const calls: string[] = []
  const fn = async (url: string) => {
    calls.push(url)
    const key = Object.keys(routes).find(k => url.includes(k))
    if (!key) throw new Error('unexpected url ' + url)
    const v = routes[key]!
    if (v instanceof Error) throw v
    return { ok: true, status: 200, json: async () => v }
  }
  return { fn, calls }
}

const AUTH = { authorization: 'k', host: 'https://bigmodel.cn', provider: 'bigmodel-individual-coding-plan' }

describe('parsePlanWindows / parseSubscription', () => {
  it('额度窗口：5 小时在前、周在后，口径为 总额/已用/剩余/重置时间', () => {
    const ws = parsePlanWindows(QUOTA_OK.data.limits)
    expect(ws.map(w => w.key)).toEqual(['fiveHour', 'week'])
    expect(ws.map(w => w.label)).toEqual(['5 小时窗口', '周额度'])
    expect(ws[0]).toMatchObject({ total: 12000, used: 734, remaining: 11265, percentage: 6, nextResetAt: 1789369217511 })
    expect(ws[1]).toMatchObject({ total: 60000, used: 22702, remaining: 37297, percentage: 37 })
  })
  it('未知 unit/坏行不致断', () => {
    const ws = parsePlanWindows([{ unit: 9, number: 2, usage: 10, currentValue: 1 }, null, { usage: 'x' }])
    expect(ws).toHaveLength(1)
    expect(ws[0]!.key).toBe('unit-9')
    expect(parsePlanWindows(null)).toEqual([])
  })
  it('订阅明细：取当前周期 VALID 行，解析有效期与续费', () => {
    const s = parseSubscription(SUB_OK)
    expect(s.planName).toBe('GLM Coding Pro')
    expect(s.billingCycle).toBe('quarterly')
    expect(s.validFrom).toBe('2026-12-09 10:00:00')
    expect(s.validTo).toBe('2027-03-09 10:00:00')
    expect(s.autoRenew).toBe(false)
    expect(s.nextRenewAt).toBe('2026-12-09')
  })
})

describe('fetchPlanSnapshot', () => {
  it('双接口成功 → available + 套餐与窗口齐备，lastSuccessAt 落值', async () => {
    const { fn } = fakeFetch({ 'subscription/list': SUB_OK, 'quota/limit': QUOTA_OK })
    const snap = await fetchPlanSnapshot(AUTH, fn, 1000)
    expect(snap.available).toBe(true)
    expect(snap.planName).toBe('GLM Coding Pro')
    expect(snap.level).toBe('pro')
    expect(snap.windows).toHaveLength(2)
    expect(snap.lastSuccessAt).toBe(1000)
    expect(snap.error).toBeNull()
  })
  it('仅额度接口成功也可用；订阅失败进 error 但不整体置为不可用', async () => {
    const { fn } = fakeFetch({ 'subscription/list': new Error('boom'), 'quota/limit': QUOTA_OK })
    const snap = await fetchPlanSnapshot(AUTH, fn, 1000)
    expect(snap.available).toBe(true)
    expect(snap.windows).toHaveLength(2)
    expect(snap.error).toBe('boom')
  })
  it('双 401 → http_401；HTTP 错误 → http_error；业务错误码 → error 透出', async () => {
    const e401 = Object.assign(new Error('HTTP 401'), { planHttpStatus: 401 })
    const { fn: f401 } = fakeFetch({ 'subscription/list': e401, 'quota/limit': e401 })
    const s401 = await fetchPlanSnapshot(AUTH, f401, 1000)
    expect(s401.available).toBe(false)
    expect(s401.unavailableReason).toBe('http_401')

    const e500 = Object.assign(new Error('HTTP 500'), { planHttpStatus: 500 })
    const { fn: f500 } = fakeFetch({ 'subscription/list': e500, 'quota/limit': e500 })
    expect((await fetchPlanSnapshot(AUTH, f500, 1000)).unavailableReason).toBe('http_error')

    const { fn: fBad } = fakeFetch({ 'subscription/list': { code: 3001, msg: 'parameter error' }, 'quota/limit': { code: 3001, msg: 'parameter error' } })
    const sBad = await fetchPlanSnapshot(AUTH, fBad, 1000)
    expect(sBad.available).toBe(false)
    expect(sBad.error).toBe('parameter error')
  })
  it('接口通但无套餐数据 → no_plan', async () => {
    const { fn } = fakeFetch({ 'subscription/list': { code: 200, data: [] }, 'quota/limit': { code: 200, data: {} } })
    const snap = await fetchPlanSnapshot(AUTH, fn, 1000)
    expect(snap.available).toBe(false)
    expect(snap.unavailableReason).toBe('no_plan')
  })
})
