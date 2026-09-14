// server/tests/api.test.ts — handleApi route table over a mock snapshot.
// Pure test: api.ts + aggregate.ts only; collector's heavy codeburn imports are
// dynamic (lazily loaded at refresh time), so nothing heavy loads here.
import { describe, it, expect } from 'vitest'
import { handleApi } from '../src/api.js'
import type { Snapshot } from '../src/collector.js'

const HOUR = 3600 * 1000
const DAY = 24 * HOUR
// Relative to Date.now(), not a fixed date: handleApi computes the ?range=
// windows against the real clock (api.ts uses Date.now()), so a pinned NOW
// would silently push every row out of the 7d window as real time advances.
const NOW = Date.now()

const snap: Snapshot = {
  fetchedAt: 1234,
  lastSuccessAt: 1200,
  refreshing: false,
  errors: ['earlier refresh failed'],
  rows: [
    { host: 'macair', tool: 'zcode', model: 'glm-5.2', ts: NOW - 1 * HOUR, project: 'p', tin: 10, tout: 5, tcacheRead: 100, tcacheWrite: 0, treason: 1, cost: 0.5, costEstimated: false },
    { host: 'macpro', tool: 'codex', model: 'gpt-5.2', ts: NOW - 2 * DAY, project: 'q', tin: 1, tout: 2, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: null, costEstimated: true },
    { host: 'macpro', tool: 'codex', model: 'gpt-5.2', ts: NOW - 40 * DAY, project: 'q', tin: 7, tout: 7, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 9, costEstimated: false },
  ],
}

const get = (path: string) => handleApi(new URL(path, 'http://127.0.0.1'), snap, 'macair')

describe('handleApi', () => {
  it('GET /api/overview totals, byHost, and passes fetchedAt/errors through', () => {
    const { status, body } = get('/api/overview')
    expect(status).toBe(200)
    const b = body as { totalTokens: number; calls: number; byHost: Record<string, { tokens: number }>; fetchedAt: number; errors: string[] }
    // rows: 116 + 3 + 14 tokens
    expect(b.totalTokens).toBe(133)
    expect(b.calls).toBe(3)
    expect(b.byHost['macair']!.tokens).toBe(116)
    expect(b.byHost['macpro']!.tokens).toBe(17)
    expect(b.fetchedAt).toBe(1234)
    expect(b.errors).toEqual(['earlier refresh failed'])
  })

  it('GET /api/overview exposes lastSuccessAt and estimatedCost alongside totals', () => {
    const b = get('/api/overview').body as Record<string, any>
    expect(b.lastSuccessAt).toBe(1200)
    // 估算成本 = costEstimated 行的成本和（gpt-5.2 那行 cost=null，不计入）→ 0
    expect(b.estimatedCost).toBe(0)
    expect(b.allTime.estimatedCost).toBe(0)
  })

  it('GET /api/overview?range= scopes top level to the window and preserves allTime', () => {
    // Rows tuned so the brief's core assertions hold: recent row = 150 tokens
    // (100 tin + 50 tout), old row = 10; 7d window keeps only the recent one.
    const ranged: Snapshot = {
      fetchedAt: 1234,
      lastSuccessAt: 1234,
      refreshing: false,
      errors: [],
      rows: [
        { host: 'macair', tool: 'zcode', model: 'm', ts: NOW - 1 * HOUR, project: 'p', tin: 100, tout: 50, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 1, costEstimated: false },
        { host: 'macpro', tool: 'codex', model: 'm', ts: NOW - 40 * DAY, project: 'q', tin: 7, tout: 3, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0.5, costEstimated: false },
      ],
    }
    const body = handleApi(new URL('http://127.0.0.1/api/overview?range=7d'), ranged, 'macair').body as Record<string, any>
    // Top level = range-scoped aggregation (recent row only).
    expect(body.totalTokens).toBe(150)
    expect(body.calls).toBe(1)
    // allTime = same shape over every row, without fetchedAt/errors.
    expect(body.allTime.totalTokens).toBe(160)
    expect(body.allTime.calls).toBe(2)
    expect(body.allTime.byHost).toEqual({ macair: { tokens: 150, cost: 1, calls: 1 }, macpro: { tokens: 10, cost: 0.5, calls: 1 } })
    expect(body.allTime.fetchedAt).toBeUndefined()
    expect(body.allTime.errors).toBeUndefined()
    expect(body.fetchedAt).toBe(1234)
    expect(body.errors).toEqual([])
  })

  it('GET /api/overview?range=all keeps top level identical to allTime', () => {
    const body = get('/api/overview?range=all').body as Record<string, any>
    expect(body.totalTokens).toBe(133)
    expect(body.allTime.totalTokens).toBe(133)
    expect(body.allTime).toEqual({
      totalTokens: 133, totalCost: 9.5, calls: 3, cacheHitRate: body.cacheHitRate,
      activeDays: body.activeDays, byHost: body.byHost, byTool: body.byTool, estimatedCost: 0,
    })
  })

  it('GET /api/overview applies dimension filters to totals (KPI 不再无视钻取)', () => {
    const b = get('/api/overview?hosts=macpro&range=all').body as Record<string, any>
    expect(b.totalTokens).toBe(17)
    expect(b.calls).toBe(2)
    // 分面：byHost 忽略 hosts 过滤 → 两台设备仍在（可继续点选/取消）
    expect(Object.keys(b.byHost).sort()).toEqual(['macair', 'macpro'])
    expect(b.byHost['macair']!.tokens).toBe(116)
    // byTool 不忽略 hosts 过滤 → 只剩 macpro 上用过的工具
    expect(Object.keys(b.byTool)).toEqual(['codex'])
    // models/projects 维度过滤同样生效
    const byModel = get('/api/overview?models=glm-5.2&range=all').body as Record<string, any>
    expect(byModel.totalTokens).toBe(116)
    const byProject = get('/api/overview?projects=p&range=all').body as Record<string, any>
    expect(byProject.totalTokens).toBe(116)
  })

  it('GET /api/overview?compare=previous 对上一等长窗口跑同一聚合（KPI 环比）', () => {
    // 7d 窗口 = [now-7d, now)，上一窗口 = [now-14d, now-7d)：放入两行专属数据
    const ranged: Snapshot = {
      fetchedAt: 1234, lastSuccessAt: 1234, refreshing: false, errors: [],
      rows: [
        { host: 'macair', tool: 'zcode', model: 'm', ts: NOW - 1 * HOUR, project: 'p', tin: 100, tout: 50, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 1, costEstimated: false },
        { host: 'macpro', tool: 'codex', model: 'm', ts: NOW - 10 * DAY, project: 'q', tin: 20, tout: 10, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0.5, costEstimated: false },
        // 18 天前：两个窗口都装不下，仅影响 allTime
        { host: 'macpro', tool: 'codex', model: 'm', ts: NOW - 18 * DAY, project: 'q', tin: 7, tout: 3, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0.5, costEstimated: false },
      ],
    }
    const body = handleApi(new URL('http://127.0.0.1/api/overview?range=7d&compare=previous'), ranged, 'macair').body as Record<string, any>
    expect(body.totalTokens).toBe(150)
    expect(body.prev).toEqual({
      totalTokens: 30, totalCost: 0.5, calls: 1, cacheHitRate: body.prev.cacheHitRate, activeDays: 1,
    })
    // 不带 compare 或 range=all → prev 为 null（无上一窗口语义）
    const plain = handleApi(new URL('http://127.0.0.1/api/overview?range=7d'), ranged, 'macair').body as Record<string, any>
    expect(plain.prev).toBeNull()
    const allTime = get('/api/overview?range=all&compare=previous').body as Record<string, any>
    expect(allTime.prev).toBeNull()
    // 未知 compare 值 → 400
    expect(get('/api/overview?compare=bogus').status).toBe(400)
  })

  it('GET /api/overview?range=today 覆盖本地零点以来的行', () => {
    const midnight = new Date(); midnight.setHours(0, 0, 0, 0)
    const ranged: Snapshot = {
      fetchedAt: 1234, lastSuccessAt: 1234, refreshing: false, errors: [],
      rows: [
        // 今天零点后 1 分钟：必然落在 today 窗口内（测试在一天内任意时刻跑都成立）
        { host: 'macair', tool: 'zcode', model: 'm', ts: midnight.getTime() + 60_000, project: 'p', tin: 11, tout: 0, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0.1, costEstimated: false },
        { host: 'macair', tool: 'zcode', model: 'm', ts: NOW - 2 * DAY, project: 'p', tin: 99, tout: 0, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 1, costEstimated: false },
      ],
    }
    const body = handleApi(new URL('http://127.0.0.1/api/overview?range=today'), ranged, 'macair').body as Record<string, any>
    expect(body.totalTokens).toBe(11)
    expect(body.calls).toBe(1)
    expect(body.allTime.totalTokens).toBe(110)
  })

  it('GET /api/series?group=total 合并为单一系列（主图「总计」视图）', () => {
    const b = get('/api/series?group=total').body as { series: Record<string, number[]> }
    expect(Object.keys(b.series)).toEqual(['总计'])
    expect(b.series['总计']!.reduce((s, v) => s + v, 0)).toBe(133)
  })

  it('GET /api/series defaults (day × model × tokens, all) and honors range=7d', () => {
    const all = get('/api/series').body as { series: Record<string, (number | null)[]>; unit: string }
    expect(Object.keys(all.series).sort()).toEqual(['glm-5.2', 'gpt-5.2'])
    expect(Object.values(all.series).flat().reduce((s, v) => s! + (v ?? 0), 0)).toBe(133)
    expect(all.unit).toBe('tokens')
    const week = get('/api/series?bucket=day&group=host&range=7d').body as { series: Record<string, number[]> }
    expect(week.series['macair']!.reduce((s, v) => s + v, 0)).toBe(116)
    // 40-day-old macpro row excluded by the 7d window
    expect(week.series['macpro']!.reduce((s, v) => s + v, 0)).toBe(3)
  })

  it('GET /api/series applies dimension filters', () => {
    const b = get('/api/series?group=host&hosts=macair').body as { series: Record<string, number[]> }
    expect(Object.keys(b.series)).toEqual(['macair'])
  })

  it('GET /api/matrix defaults to rows=host × model columns and honors filters/range', () => {
    const { status, body } = get('/api/matrix')
    expect(status).toBe(200)
    const b = body as { rowKeys: string[]; colKeys: string[]; values: (number | null)[][] }
    expect(b.rowKeys).toEqual(['macair', 'macpro'])
    expect(b.colKeys).toEqual(['glm-5.2', 'gpt-5.2'])
    // macpro holds both gpt-5.2 rows (3 + 14 tokens)
    expect(b.values).toEqual([[116, null], [null, 17]])
    // rows=project override
    const byProject = get('/api/matrix?rows=project').body as { rowKeys: string[] }
    expect(byProject.rowKeys).toEqual(['p', 'q'])
    // 统一筛选（此前矩阵恒为全历史全量）：hosts + range 都生效；
    // 过滤后 colKeys 也只剩过滤范围内出现过的模型
    const filtered = get('/api/matrix?rows=host&hosts=macair&range=7d').body as { rowKeys: string[]; colKeys: string[]; values: (number | null)[][] }
    expect(filtered.rowKeys).toEqual(['macair'])
    expect(filtered.colKeys).toEqual(['glm-5.2'])
    expect(filtered.values).toEqual([[116]])
  })

  it('GET /api/models sorts by total tokens (统一口径，含缓存读) and honors filters', () => {
    const { status, body } = get('/api/models')
    expect(status).toBe(200)
    const b = body as Array<{ model: string; calls: number; tin: number; tokens: number }>
    // glm-5.2: 116 tokens（10+5+1 输入输出推理 + 100 缓存读），gpt-5.2: 17 → glm-5.2 first
    expect(b.map(m => m.model)).toEqual(['glm-5.2', 'gpt-5.2'])
    expect(b[0]!.calls).toBe(1)
    expect(b[0]!.tokens).toBe(116)
    // 工具过滤下推
    const filtered = get('/api/models?tools=codex').body as Array<{ model: string }>
    expect(filtered.map(m => m.model)).toEqual(['gpt-5.2'])
  })

  it('GET /api/status reports the caller-supplied localHost, snapshot state, and freshness split', () => {
    const { status, body } = get('/api/status')
    expect(status).toBe(200)
    expect(body).toEqual({
      localHost: 'macair', fetchedAt: 1234, lastSuccessAt: 1200, refreshing: false,
      errors: ['earlier refresh failed'], recordCount: 3,
    })
  })

  it('GET /api/status merges the entrypoint handshake (configPath/instanceId)', () => {
    const b = handleApi(new URL('http://127.0.0.1/api/status'), snap, 'macair', { instanceId: 'id-1', configPath: '/x/agg.config.json', port: 8317 }).body as Record<string, unknown>
    expect(b['instanceId']).toBe('id-1')
    expect(b['configPath']).toBe('/x/agg.config.json')
    expect(b['port']).toBe(8317)
  })

  it('invalid query params → 400 with an error message (不再静默换语义)', () => {
    for (const path of [
      '/api/overview?range=bogus',
      '/api/series?bucket=week',
      '/api/series?group=galaxy',
      '/api/series?metric=horses',
      '/api/matrix?rows=nothing',
      '/api/models?range=1h',
    ]) {
      const { status, body } = get(path)
      expect(status, path).toBe(400)
      expect((body as { error: string }).error, path).toMatch(/未知|不合法/)
    }
  })

  it('GET /api/plan passes the entrypoint-polled snapshot; absent → empty accounts', () => {
    const plan = {
      accounts: [{
        kind: 'glm' as const, label: 'GLM Coding Plan', available: true, unavailableReason: null,
        error: null, planName: 'GLM Coding Pro', windows: [], fetchedAt: 1, lastSuccessAt: 1,
      }],
    }
    const withPlan = handleApi(new URL('http://127.0.0.1/api/plan'), snap, 'macair', undefined, plan).body as Record<string, unknown>
    const accounts = withPlan['accounts'] as Array<Record<string, unknown>>
    expect(accounts[0]!['planName']).toBe('GLM Coding Pro')
    const without = handleApi(new URL('http://127.0.0.1/api/plan'), snap, 'macair').body as Record<string, unknown>
    expect(Array.isArray(without['accounts'])).toBe(true)
  })

  it('unknown /api/ path → 404', () => {
    const { status, body } = get('/api/nope')
    expect(status).toBe(404)
    expect(body).toEqual({ error: 'not found' })
  })
})
