// server/src/collector.ts — builds a Snapshot of usage rows by driving the
// codeburn parse pipeline (parseAllSessions → session cache → rowsFromCache).
//
// Deviations from the brief sketch (documented in task-7-report.md):
// 1. `parseAllSessions` / `loadCache` are imported *lazily* (dynamic import at
//    refresh time) instead of at module top level. `@codeburn/parser.js` pulls
//    in every provider module (~30 eager imports); keeping it lazy lets tests
//    import this module cheaply and defers the heavy graph until first refresh.
// 2. Both are injectable via constructor opts (test seam): `parseAll` /
//    `loadCache`. Production passes nothing and gets the real codeburn fns.
// 3. `rowsFromCache` runs inside the same try/catch as `loadCache` so ANY
//    refresh failure lands in snapshot.errors and old rows are preserved
//    (the brief's stated contract; the sketch left it outside the try).
import { hostname } from 'node:os'
import { loadDeviceRoots, type DeviceRoot } from '@codeburn/providers/device-roots.js'
import { rowsFromCache, type UsageRow } from './aggregate.js'
import type { SessionCache } from '@codeburn/session-cache.js'

export type Snapshot = {
  rows: UsageRow[]
  fetchedAt: number
  // 最近一次「成功」采集时间；失败轮保留旧值。fetchedAt 是最后一次尝试时间——
  // 失败时也推进，若不拆分，「数据时间」会把失败尝试误报成新数据
  lastSuccessAt: number | null
  errors: string[]
  refreshing: boolean
}

const errMsg = (err: unknown): string => (err instanceof Error ? err.message : String(err))

export class Collector {
  readonly devices: DeviceRoot[]
  readonly localHost: string
  snapshot: Snapshot = { rows: [], fetchedAt: 0, lastSuccessAt: null, errors: [], refreshing: false }
  private lock: Promise<void> | null = null
  private readonly parseAll?: () => Promise<unknown>
  private readonly loadCacheOpt?: () => Promise<SessionCache>

  constructor(opts: { devices?: DeviceRoot[]; localHost?: string; parseAll?: () => Promise<unknown>; loadCache?: () => Promise<SessionCache> } = {}) {
    this.devices = opts.devices ?? loadDeviceRoots()
    this.localHost = opts.localHost ?? hostname().replace(/\..*$/, '')
    this.parseAll = opts.parseAll
    this.loadCacheOpt = opts.loadCache
  }

  async refresh(): Promise<Snapshot> {
    if (this.lock) return this.lock.then(() => this.snapshot)
    this.snapshot = { ...this.snapshot, refreshing: true }
    this.lock = (async () => {
      const errors: string[] = []
      try {
        if (this.parseAll) await this.parseAll()
        else await (await import('@codeburn/parser.js')).parseAllSessions() // 全量管线，增量缓存使其快速；同时把缓存写盘
      } catch (err) { errors.push(`parseAllSessions: ${errMsg(err)}`) }
      let rows: UsageRow[] = this.snapshot.rows
      if (errors.length === 0) {
        try {
          const cache = this.loadCacheOpt
            ? await this.loadCacheOpt()
            : await (await import('@codeburn/session-cache.js')).loadCache()
          rows = rowsFromCache(cache, this.devices, this.localHost)
        } catch (err) { errors.push(`loadCache: ${errMsg(err)}`) }
      }
      // 失败轮：fetchedAt 推进（尝试时间），lastSuccessAt 保留上一个成功值
      this.snapshot = {
        rows,
        fetchedAt: Date.now(),
        lastSuccessAt: errors.length === 0 ? Date.now() : this.snapshot.lastSuccessAt,
        errors,
        refreshing: false,
      }
    })().finally(() => { this.lock = null })
    return this.lock.then(() => this.snapshot)
  }
}
