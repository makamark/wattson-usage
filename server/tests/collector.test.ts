// server/tests/collector.test.ts — Collector.refresh concurrency + error
// handling, using injected fakes for parseAll/loadCache (the brief sketch had
// no DI seam; the constructor opts are additive and production passes nothing).
// No heavy codeburn module is loaded: both real implementations are dynamic
// imports inside refresh(), and SessionCache here is a type-only import.
import { describe, it, expect } from 'vitest'
import { Collector } from '../src/collector.js'
import type { SessionCache } from '@codeburn/session-cache.js'

function makeCache(): SessionCache {
  return {
    version: 9, complete: true,
    providers: {
      zcode: {
        envFingerprint: 'x',
        files: {
          '/Users/x/.zcode/cli/db/db.sqlite:s1': {
            fingerprint: { dev: 1, ino: 1, mtimeMs: 1, sizeBytes: 1 }, mcpInventory: [],
            turns: [{ timestamp: '2026-09-10T02:00:00.000Z', sessionId: 's1', userMessage: '', calls: [
              { provider: 'zcode', model: 'glm-5.2', usage: { inputTokens: 10, outputTokens: 5, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, reasoningTokens: 1, webSearchRequests: 0 }, costUSD: 0.01, speed: 'standard', timestamp: '2026-09-10T02:00:00.000Z', tools: [], bashCommands: [], skills: [], subagentTypes: [], deduplicationKey: 'zcode:u1' },
            ] }],
          },
        },
      },
    },
  } as unknown as SessionCache
}

/** Manually resolved promise: holds refresh() open so calls can be timed/interleaved. */
function gate() {
  let resolve!: () => void
  const promise = new Promise<void>(r => { resolve = r })
  return { promise, resolve: () => resolve() }
}

describe('Collector.refresh', () => {
  it('coalesces concurrent refresh() calls into a single parse', async () => {
    let parseCalls = 0
    let g = gate()
    const c = new Collector({
      devices: [], localHost: 'testhost',
      parseAll: () => { parseCalls += 1; return g.promise },
      loadCache: async () => makeCache(),
    })
    // Three synchronous back-to-back calls must share one in-flight refresh.
    const p1 = c.refresh(); const p2 = c.refresh(); const p3 = c.refresh()
    expect(parseCalls).toBe(1)
    expect(c.snapshot.refreshing).toBe(true)
    g.resolve()
    const [s1, s2, s3] = await Promise.all([p1, p2, p3])
    expect(parseCalls).toBe(1)
    expect(c.snapshot.refreshing).toBe(false)
    expect(s1.errors).toEqual([])
    expect(s1.rows).toHaveLength(1)
    // All callers observe the same settled snapshot object.
    expect(s1).toBe(s2); expect(s2).toBe(s3); expect(s1).toBe(c.snapshot)
    // After settle the lock is cleared: a new refresh runs a new parse.
    g = gate()
    const p4 = c.refresh()
    expect(parseCalls).toBe(2)
    g.resolve()
    await p4
    expect(parseCalls).toBe(2)
  })

  it('calls chained onto an in-flight refresh also see exactly one parse', async () => {
    let parseCalls = 0
    const g = gate()
    const c = new Collector({
      devices: [], localHost: 'h',
      parseAll: () => { parseCalls += 1; return g.promise },
      loadCache: async () => makeCache(),
    })
    const first = c.refresh()
    await Promise.resolve() // let the first refresh assign its lock
    const chained = Promise.all([c.refresh(), c.refresh(), c.refresh(), c.refresh()])
    expect(parseCalls).toBe(1)
    g.resolve()
    const results = await chained
    await first
    expect(parseCalls).toBe(1)
    expect(results.every(s => s.refreshing === false && s.rows.length === 1)).toBe(true)
  })

  it('a parse failure records the error and keeps the previous rows', async () => {
    let failParse = false
    let loadCacheCalls = 0
    const c = new Collector({
      devices: [], localHost: 'h',
      parseAll: async () => { if (failParse) throw new Error('cold parse exploded') },
      loadCache: async () => { loadCacheCalls += 1; return makeCache() },
    })
    const first = await c.refresh()
    expect(first.errors).toEqual([])
    expect(first.rows).toHaveLength(1)
    expect(first.lastSuccessAt).toBeGreaterThan(0)

    // Second round: parse explodes; loadCache must be skipped, rows preserved.
    failParse = true
    const s = await c.refresh()
    expect(s.errors).toEqual(['parseAllSessions: cold parse exploded'])
    expect(s.rows).toBe(first.rows) // old snapshot rows preserved by reference
    expect(s.refreshing).toBe(false)
    expect(s.fetchedAt).toBeGreaterThanOrEqual(first.fetchedAt)
    // 新鲜度拆分：失败轮 fetchedAt（尝试时间）推进，lastSuccessAt（成功时间）保留旧值
    expect(s.lastSuccessAt).toBe(first.lastSuccessAt)
    expect(loadCacheCalls).toBe(1) // unchanged: skipped on the failing round
  })

  it('a loadCache/rowsFromCache failure also lands in errors (rows preserved)', async () => {
    const c = new Collector({
      devices: [], localHost: 'h',
      parseAll: async () => undefined,
      loadCache: async () => { throw new Error('cache file corrupt') },
    })
    const s = await c.refresh()
    expect(s.errors).toEqual(['loadCache: cache file corrupt'])
    expect(s.rows).toEqual([])
    expect(s.refreshing).toBe(false)
  })

  it('happy path: rowsFromCache output lands in the snapshot with localHost defaulting', async () => {
    const c = new Collector({ devices: [], localHost: 'macair', parseAll: async () => undefined, loadCache: async () => makeCache() })
    const s = await c.refresh()
    expect(s.errors).toEqual([])
    expect(s.rows[0]).toMatchObject({ host: 'macair', tool: 'zcode', model: 'glm-5.2', tin: 10, tout: 5, treason: 1 })
    expect(s.fetchedAt).toBeGreaterThan(0)
  })
})
