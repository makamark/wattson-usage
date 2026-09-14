// server/tests/aggregate.test.ts
import { describe, it, expect } from 'vitest'
import { rowsFromCache, series, overview, matrix, modelTable, filterRows, rowTokens, type UsageRow } from '../src/aggregate.js'

const DAY = 24 * 3600 * 1000
const HOUR = 3600 * 1000

// First calendar day of 2026 in the *process* timezone whose local wall-clock
// length differs from 24h (i.e. a DST transition day). Returns null in DST-free
// zones (e.g. Asia/Shanghai) — callers may skip the DST regression test there
// and run it instead with `TZ=America/New_York npm test`.
function firstDstTransitionDayStart(): number | null {
  for (let month = 0; month < 12; month++) {
    for (let day = 1; day <= 31; day++) {
      const t0 = new Date(2026, month, day).getTime()
      const t1 = new Date(2026, month, day + 1).getTime()
      if (t1 - t0 !== DAY) return t0
    }
  }
  return null
}
const dstDayStart = firstDstTransitionDayStart()

function row(partial: Partial<UsageRow>): UsageRow {
  return { host: 'macair', tool: 'zcode', model: 'm1', ts: 0, project: 'p', tin: 0, tout: 0,
    tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0, costEstimated: false, ...partial }
}

describe('rowsFromCache', () => {
  it('flattens cache to rows with host from path prefix', async () => {
    const { expandHome } = await import('@codeburn/providers/device-roots.js')
    const remoteDb = expandHome('~/mirror/zcode/db.sqlite')
    const cache = {
      version: 9, complete: true,
      providers: {
        zcode: {
          envFingerprint: 'x',
          files: {
            '/Users/tester/.zcode/cli/db/db.sqlite:s1': {
              fingerprint: { dev: 1, ino: 1, mtimeMs: 1, sizeBytes: 1 }, mcpInventory: [],
              turns: [{ timestamp: '2026-09-10T02:00:00.000Z', sessionId: 's1', userMessage: '', calls: [
                { provider: 'zcode', model: 'glm-5.2', usage: { inputTokens: 100, outputTokens: 10, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, cachedInputTokens: 0, reasoningTokens: 5, webSearchRequests: 0 }, costUSD: 0.01, speed: 'standard', timestamp: '2026-09-10T02:00:00.000Z', tools: [], bashCommands: [], skills: [], subagentTypes: [], deduplicationKey: 'zcode:u1' },
              ] }],
            },
            [`${remoteDb}:s2`]: {
              fingerprint: { dev: 1, ino: 2, mtimeMs: 1, sizeBytes: 1 }, mcpInventory: [], turns: [],
            },
          },
        },
      },
    } as never
    const devices = [{ host: 'macpro', zcodeDb: remoteDb }]
    const rows = rowsFromCache(cache, devices, 'macair')
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ host: 'macair', tool: 'zcode', model: 'glm-5.2', tin: 100, tout: 10, treason: 5, cost: 0.01, costEstimated: false })
  })

  it('reprices calls cached without costUSD and flags them estimated', () => {
    // codeburn's cache-write whitelist (parser.ts providerCallToCachedCall)
    // leaves costUSD undefined for zcode/codex/workbuddy. rowsFromCache must
    // reprice via billableOutputTokens + calculateCost — the same semantics as
    // codeburn's own read path (cachedCallToApiCall) — and mark the row as an
    // estimate; otherwise the cost KPI is permanently null for those tools.
    // glm-5.2 is in the embedded litellm snapshot, so the reprice is > 0;
    // zcode is not a reasoning-in-output provider, so tout+treason = 15 bills.
    const cache = {
      version: 9, complete: true,
      providers: {
        zcode: {
          envFingerprint: 'x',
          files: {
            '/Users/tester/.zcode/cli/db/db.sqlite:s1': {
              fingerprint: { dev: 1, ino: 1, mtimeMs: 1, sizeBytes: 1 }, mcpInventory: [],
              turns: [{ timestamp: '2026-09-10T02:00:00.000Z', sessionId: 's1', userMessage: '', calls: [
                { provider: 'zcode', model: 'glm-5.2', usage: { inputTokens: 100, outputTokens: 10, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, cachedInputTokens: 0, reasoningTokens: 5, webSearchRequests: 0 }, speed: 'standard', timestamp: '2026-09-10T02:00:00.000Z', tools: [], bashCommands: [], skills: [], subagentTypes: [], deduplicationKey: 'zcode:u1' },
              ] }],
            },
          },
        },
      },
    } as never
    const rows = rowsFromCache(cache, [], 'macair')
    expect(rows).toHaveLength(1)
    expect(rows[0]!.cost).toBeGreaterThan(0)
    expect(rows[0]!.costEstimated).toBe(true)
  })
})

describe('series', () => {
  const rows = [
    row({ ts: 1757464800000, host: 'macair', tin: 100, tout: 50, cost: 1 }),
    row({ ts: 1757464800000 + 1000, host: 'macpro', model: 'm2', tin: 10, tout: 5, cost: null }),
    row({ ts: 1757464800000 + 2 * DAY, host: 'macair', tin: 7, tout: 3, cost: 0.5 }),
  ]
  it('day × host tokens with aligned times and null-free gaps', () => {
    const r = series(rows, { bucket: 'day', group: 'host', rangeMs: null, metric: 'tokens', now: 1757464800000 + 3 * DAY })
    expect(r.times.length).toBeGreaterThanOrEqual(3)
    const a = r.series['macair']!, b = r.series['macpro']!
    expect(a.reduce((s, v) => s! + (v ?? 0), 0)).toBe(160)
    expect(b.reduce((s, v) => s! + (v ?? 0), 0)).toBe(15)
    // tokens metric must never emit null (the ?? 0 above must not mask one)
    expect(a.includes(null)).toBe(false)
    expect(b.includes(null)).toBe(false)
  })
  it('cost metric carries null for unpriced models', () => {
    const r = series(rows, { bucket: 'day', group: 'host', rangeMs: null, metric: 'cost', now: 1757464800000 + 3 * DAY })
    expect(r.series['macpro']!.some(v => v === null)).toBe(true)
  })

  // Regression (review finding): the time axis used to advance in fixed epoch
  // steps (t += DAY) while rows are assigned via local-timezone bucketStart().
  // Across a DST transition a local day is 23h/25h, so the grid drifted off the
  // bucket starts and `index.get(...)!` returned undefined → TypeError.
  // Skips automatically in DST-free zones; run it there with:
  //   TZ=America/New_York npm test
  it.skipIf(dstDayStart === null)('DST transition day: grid stays on local bucket starts (no crash, full coverage)', () => {
    const day0 = dstDayStart! // non-null: skipIf guarantees a transition exists
    const rows = [
      row({ ts: day0 - 12 * HOUR, host: 'macair', tin: 1 }), // noon the day before
      row({ ts: day0 + 3 * HOUR, host: 'macair', tin: 4 }),  // early on the transition day
      row({ ts: day0 + 36 * HOUR, host: 'macair', tin: 2 }), // noon the day after
    ]
    const r = series(rows, { bucket: 'day', group: 'host', rangeMs: null, metric: 'tokens', now: day0 + 36 * HOUR })
    // Oracle: enumerate local midnights via calendar arithmetic (Date handles DST).
    const expected: number[] = []
    const d = new Date(rows[0]!.ts)
    d.setHours(0, 0, 0, 0)
    for (;;) {
      if (d.getTime() > rows[2]!.ts) break
      expected.push(d.getTime())
      d.setDate(d.getDate() + 1)
      d.setHours(0, 0, 0, 0)
    }
    expect(r.times).toEqual(expected)
    expect(r.series['macair']).toEqual([1, 4, 2])
  })
})

describe('rowTokens / 统一口径', () => {
  it('reasoning-in-output 提供商（codex）不把 reasoningTokens 加第二次', () => {
    // 修复前：rowTokens 无条件 tout+treason → codex/claude/copilot 的总量系统性偏高
    const codex = row({ tool: 'codex', tin: 100, tout: 50, treason: 20 })
    expect(rowTokens(codex)).toBe(150) // reasoning 是 output 子集：100+50，不是 170
    const zcode = row({ tool: 'zcode', tin: 100, tout: 50, treason: 20 })
    expect(rowTokens(zcode)).toBe(170) // 独立推理口径：100+50+20
  })

  it('overview/matrix/series 全部复用同一口径（codex 行不再双计）', () => {
    const rows = [row({ host: 'h1', model: 'm1', tool: 'codex', tin: 100, tout: 50, treason: 20 })]
    expect(overview(rows).totalTokens).toBe(150)
    expect(matrix(rows, 'host', 'model').values[0]![0]).toBe(150)
    const s = series(rows, { bucket: 'day', group: 'host', rangeMs: null, metric: 'tokens', now: Date.now() })
    expect(Object.values(s.series).flat().reduce<number>((a, v) => a + (v ?? 0), 0)).toBe(150)
  })
})

describe('原型键安全', () => {
  it('host 名为 constructor/hasOwnProperty 时聚合不被继承属性击穿', () => {
    // 修复前：普通字面量做映射表，'constructor' 命中 Object.prototype → byHost 序列化为空
    const rows = [
      row({ host: 'constructor', tin: 5 }),
      row({ host: 'hasOwnProperty', tin: 7 }),
      row({ host: 'normal', tin: 1 }),
    ]
    const o = overview(rows)
    expect(Object.keys(o.byHost).sort()).toEqual(['constructor', 'hasOwnProperty', 'normal'])
    expect(o.byHost['constructor']!.tokens).toBe(5)
    const s = series(rows, { bucket: 'day', group: 'host', rangeMs: null, metric: 'tokens', now: 0 })
    expect(Object.keys(s.series).sort()).toEqual(['constructor', 'hasOwnProperty', 'normal'])
    expect(s.series['hasOwnProperty']!.reduce<number>((a, v) => a + (v ?? 0), 0)).toBe(7)
  })
})

describe('filterRows（统一筛选）', () => {
  const rows = [
    row({ ts: 10 * DAY, host: 'a', tool: 'zcode', model: 'm1', project: 'p1', tin: 1 }),
    row({ ts: 2 * DAY, host: 'b', tool: 'codex', model: 'm2', project: 'p2', tin: 2 }),
  ]
  it('range 与维度集合同时生效，空集合 = 不过滤', () => {
    expect(filterRows(rows, { rangeMs: 5 * DAY, hosts: [], tools: [], models: [], projects: [] }, 10 * DAY)).toEqual([rows[0]])
    expect(filterRows(rows, { rangeMs: null, hosts: ['b'], tools: [], models: [], projects: [] }, 10 * DAY)).toEqual([rows[1]])
    expect(filterRows(rows, { rangeMs: null, hosts: [], tools: ['codex'], models: [], projects: [] }, 10 * DAY)).toEqual([rows[1]])
    expect(filterRows(rows, { rangeMs: null, hosts: [], tools: [], models: ['m1', 'm2'], projects: [] }, 10 * DAY)).toHaveLength(2)
    expect(filterRows(rows, { rangeMs: null, hosts: [], tools: [], models: [], projects: ['none'] }, 10 * DAY)).toHaveLength(0)
  })
})

describe('series 资源边界', () => {
  it('maxSeries：超限分组按全期总量保留 Top-N-1，其余合并为「其他」，总量守恒', () => {
    const rows = Array.from({ length: 15 }, (_, i) =>
      row({ host: `h${String(i).padStart(2, '0')}`, tin: (i + 1) * 10 }))
    const r = series(rows, { bucket: 'day', group: 'host', rangeMs: null, metric: 'tokens', now: 10 * DAY, maxSeries: 5 })
    expect(Object.keys(r.series)).toHaveLength(5)
    expect(Object.keys(r.series)).toContain('其他')
    const sum = Object.values(r.series).flat().reduce<number>((a, v) => a + (v ?? 0), 0)
    expect(sum).toBe(1200) // 10+20+…+150
    // 前 4 名（h14…h11）保留，h10 以下进「其他」
    expect(r.series['h14']).toBeDefined()
    expect(r.series['h11']).toBeDefined()
    expect(r.series['h10']).toBeUndefined()
    expect(r.series['其他']!.reduce<number>((a, v) => a + (v ?? 0), 0)).toBe(660) // h00..h10 = 10+…+110
  })

  it('maxBuckets：只保留最近的时间桶，桶外行不参与分组', () => {
    const rows = [row({ ts: 0, host: 'old', tin: 5 }), row({ ts: 3 * DAY, host: 'new', tin: 7 })]
    const r = series(rows, { bucket: 'day', group: 'host', rangeMs: null, metric: 'tokens', now: 3 * DAY, maxBuckets: 2 })
    expect(r.times).toHaveLength(2)
    expect(r.series['old']).toBeUndefined()
    expect(r.series['new']!.reduce<number>((a, v) => a + (v ?? 0), 0)).toBe(7)
  })
})

describe('overview', () => {
  it('totals and cache hit rate', () => {
    const rows = [row({ tin: 100, tout: 50, tcacheRead: 100, tcacheWrite: 20, treason: 10, cost: 1 }),
      row({ host: 'macpro', tin: 10, tout: 5, cost: null })]
    const o = overview(rows)
    expect(o.totalTokens).toBe(295)
    expect(o.totalCost).toBe(1)
    expect(o.calls).toBe(2)
    expect(o.cacheHitRate).toBeCloseTo(100 / 210)
    expect(o.activeDays).toBe(1)
    expect(o.byHost['macair']!.tokens).toBe(280)
  })
})

describe('matrix / modelTable', () => {
  it('matrix aggregates tokens by row × model', () => {
    const rows = [row({ host: 'macair', model: 'm1', tin: 10, tout: 5 }),
      row({ host: 'macpro', model: 'm1', tin: 1, tout: 1 }),
      row({ host: 'macpro', model: 'm2', tin: 2, tout: 2 })]
    const m = matrix(rows, 'host', 'model')
    expect(m.rowKeys.sort()).toEqual(['macair', 'macpro'])
    expect(m.colKeys.sort()).toEqual(['m1', 'm2'])
    // Grid values: macair×m1 = 15, macpro×m1 = 2, macpro×m2 = 4, macair×m2 = null.
    expect(m.values).toEqual([[15, null], [2, 4]])
  })
  it('modelTable merges across hosts', () => {
    const rows = [row({ host: 'macair', model: 'm1', tin: 10, tout: 5 }),
      row({ host: 'macpro', model: 'm1', tin: 1, tout: 1 })]
    const t = modelTable(rows)
    expect(t).toHaveLength(1)
    expect(t[0]!.calls).toBe(2)
    expect(t[0]!.tin).toBe(11)
  })
})
