// server/src/aggregate.ts — pure aggregation layer over the codeburn session cache.
// Runtime dependencies: @codeburn/providers/device-roots.js plus @codeburn/models.js
// (cost repricing for rows cached without costUSD); SessionCache is a type-only
// import so the cache plumbing itself stays decoupled from codeburn at runtime.
import type { SessionCache } from '@codeburn/session-cache.js'
import { hostForSourcePath, type DeviceRoot } from '@codeburn/providers/device-roots.js'
import { billableOutputTokens, calculateCost } from '@codeburn/models.js'

export type UsageRow = {
  host: string; tool: string; model: string; ts: number; project: string
  tin: number; tout: number; tcacheRead: number; tcacheWrite: number; treason: number
  cost: number | null; costEstimated: boolean
}

export type Bucket = 'day' | 'hour'
/** total = 不分组的单一系列（主图「总计」视图用） */
export type Group = 'total' | 'host' | 'tool' | 'model' | 'project'
export type Metric = 'tokens' | 'cost' | 'calls'
export type SeriesResult = { times: number[]; series: Record<string, (number | null)[]>; unit: string }
export type RowFilter = { rangeMs: number | null; hosts: string[]; tools: string[]; models: string[]; projects: string[] }

const DAY = 24 * 3600 * 1000

type AnyRecord = Record<string, unknown>
const num = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0)

export function rowsFromCache(cache: SessionCache, devices: DeviceRoot[], localHost: string): UsageRow[] {
  const rows: UsageRow[] = []
  for (const [provider, section] of Object.entries(cache.providers ?? {})) {
    for (const [path, file] of Object.entries(section.files ?? {})) {
      const host = hostForSourcePath(path, localHost)
      const turns = ((file as AnyRecord).turns ?? []) as AnyRecord[]
      for (const turn of turns) {
        const calls = ((turn as AnyRecord).calls ?? []) as AnyRecord[]
        for (const call of calls) {
          const c = call as AnyRecord
          const usage = (c.usage ?? {}) as AnyRecord
          const ts = Date.parse(String(c.timestamp ?? ''))
          if (!Number.isFinite(ts)) continue
          const tin = num(usage.inputTokens), tout = num(usage.outputTokens)
          const tcacheRead = num(usage.cacheReadInputTokens), tcacheWrite = num(usage.cacheCreationInputTokens)
          const treason = num(usage.reasoningTokens)
          const tool = String(c.provider ?? provider)
          const model = String(c.model ?? 'unknown')
          const storedCost = typeof c.costUSD === 'number' && Number.isFinite(c.costUSD) ? c.costUSD : null
          // codeburn's cache-write path (parser.ts providerCallToCachedCall)
          // persists costUSD only for a whitelist of providers — zcode, codex,
          // workbuddy, … store `costUSD: undefined`. Mirror codeburn's own
          // cache-rehydration pricing (cachedCallToApiCall): billableOutputTokens
          // first so reasoning-in-output providers aren't double-billed, then
          // calculateCost. calculateCost returns 0 for unmapped models — that 0
          // is a valid cost in codeburn semantics, not a missing one, so it
          // flows through as-is instead of becoming null.
          const cost = storedCost ?? calculateCost(
            model, tin, billableOutputTokens(tool, tout, treason),
            tcacheWrite, tcacheRead, num(usage.webSearchRequests),
            c.speed === 'fast' ? 'fast' : 'standard',
            num(usage.cacheCreationOneHourTokens))
          rows.push({
            host, tool, model, ts,
            project: typeof c.project === 'string' && c.project ? c.project : 'unknown',
            tin, tout, tcacheRead, tcacheWrite, treason,
            cost,
            // CachedCall declares `isEstimated`; the brief sketch read
            // `costIsEstimated` — accept either spelling defensively. Rows
            // repriced from token counts (no stored costUSD) are estimates by
            // the same convention, hence `storedCost === null`.
            costEstimated: c.isEstimated === true || c.costIsEstimated === true || storedCost === null,
          })
        }
      }
    }
  }
  return rows
}

// token 总量口径与成本计费口径保持一致：reasoning-in-output 提供商（claude/codex/
// copilot，见 codeburn REASONING_INCLUDED_IN_OUTPUT）的 reasoningTokens 是
// outputTokens 的子集，再加一次会系统性抬高总量/趋势/矩阵；billableOutputTokens
// 与成本走同一个去重逻辑，两套数字不再打架。
export const rowTokens = (r: UsageRow): number =>
  r.tin + r.tcacheRead + r.tcacheWrite + billableOutputTokens(r.tool, r.tout, r.treason)

// 统一筛选：range + 维度值集合（空集合 = 不过滤）。所有 /api 聚合入口先过这一层，
// 保证「点选设备/工具」和时间范围在看板各区块语义一致。
export function filterRows(rows: UsageRow[], f: RowFilter, now: number): UsageRow[] {
  const cutoff = f.rangeMs !== null ? now - f.rangeMs : null
  const match = (list: string[], v: string): boolean => list.length === 0 || list.includes(v)
  return rows.filter(r =>
    (cutoff === null || r.ts >= cutoff) &&
    match(f.hosts, r.host) && match(f.tools, r.tool) &&
    match(f.models, r.model) && match(f.projects, r.project))
}

function groupValue(r: UsageRow, group: Group): string {
  if (group === 'total') return '总计'
  return group === 'host' ? r.host : group === 'tool' ? r.tool : group === 'model' ? r.model : r.project
}

function bucketStart(ts: number, bucket: Bucket): number {
  const d = new Date(ts)
  if (bucket === 'hour') { d.setMinutes(0, 0, 0); return d.getTime() }
  d.setHours(0, 0, 0, 0); return d.getTime()
}

export function series(rows: UsageRow[], opts: { bucket: Bucket; group: Group; rangeMs: number | null; metric: Metric; now: number; maxSeries?: number; maxBuckets?: number }): SeriesResult {
  let filtered = opts.rangeMs ? rows.filter(r => r.ts >= opts.now - opts.rangeMs!) : rows
  const unit = opts.bucket === 'day' ? DAY : 3600 * 1000
  // min/max via a single loop: `Math.min(...rows.map(...))` throws RangeError on
  // very large row counts and materializes two intermediate arrays.
  let minTs = Infinity, maxTs = -Infinity
  for (const r of filtered) {
    if (r.ts < minTs) minTs = r.ts
    if (r.ts > maxTs) maxTs = r.ts
  }
  const start = minTs !== Infinity ? bucketStart(minTs, opts.bucket) : bucketStart(opts.now, opts.bucket)
  const end = bucketStart(Math.max(opts.now, maxTs !== -Infinity ? maxTs : 0), opts.bucket)
  // Advance the grid by snapping to the next *local* bucket start instead of
  // adding a fixed epoch step: across a DST transition a local day is 23h/25h,
  // so a fixed step drifts off the bucket starts that rows are assigned to and
  // leaves rows without a grid cell. The raw walk keeps advancing by unit while
  // the snap fails to make progress — on a ≥25h day bucketStart(t + unit) can
  // snap back to the bucket just emitted, so iterating on the snapped value
  // would spin forever. The raw argument grows by unit each round and
  // bucketStart(x) > x − 36h, so the guard terminates within 2 rounds.
  let times: number[] = []
  for (let t = start; t <= end; ) {
    times.push(t)
    let raw = t + unit
    while (bucketStart(raw, opts.bucket) <= t) raw += unit
    t = bucketStart(raw, opts.bucket)
  }
  // 时间桶上限：range=all × hour 这类组合会产生巨型网格；只保留最近的
  // maxBuckets 个桶，窗口外的行直接不参与分组（避免其分组键挤占 Top-N）。
  if (opts.maxBuckets && times.length > opts.maxBuckets) {
    times = times.slice(-opts.maxBuckets)
    filtered = filtered.filter(r => bucketStart(r.ts, opts.bucket) >= times[0]!)
  }
  const index = new Map(times.map((t, i) => [t, i]))
  // 聚合容器统一用无原型对象：分组键来自数据（host/tool/model/project 名），
  // 普通字面量会被 'constructor' 等继承属性名击穿。
  const acc: Record<string, Array<{ sum: number; hasValue: boolean }>> = Object.create(null)
  const groupKeys = [...new Set(filtered.map(r => groupValue(r, opts.group)))].sort()
  for (const g of groupKeys) acc[g] = times.map(() => ({ sum: 0, hasValue: false }))
  for (const r of filtered) {
    const idx = index.get(bucketStart(r.ts, opts.bucket))
    // Defensive: a row whose bucket start is not on the grid is skipped instead
    // of crashing on a non-null assertion.
    if (idx === undefined) continue
    const cell = acc[groupValue(r, opts.group)]![idx]
    if (opts.metric === 'calls') { cell.sum += 1 } else if (opts.metric === 'cost') {
      if (r.cost !== null) { cell.sum += r.cost; cell.hasValue = true }
    } else { cell.sum += rowTokens(r) }
  }
  // Top-N：分组数超上限时按全期总量保留前 N-1 名，其余合并为「其他」，
  // 防止高基数维度（如 project）撑爆图例与响应体。
  let outKeys = groupKeys
  const mergeTarget = groupKeys.includes('其他') ? '其他*' : '其他'
  if (opts.maxSeries && groupKeys.length > opts.maxSeries) {
    const totalOf = (g: string): number =>
      acc[g]!.reduce((s, c) => s + (opts.metric === 'cost' && !c.hasValue ? 0 : c.sum), 0)
    const keep = [...groupKeys].sort((a, b) => totalOf(b) - totalOf(a) || (a < b ? -1 : 1)).slice(0, opts.maxSeries - 1)
    const rest = groupKeys.filter(g => !keep.includes(g))
    acc[mergeTarget] = times.map(() => ({ sum: 0, hasValue: false }))
    for (const g of rest) {
      const from = acc[g]!, to = acc[mergeTarget]!
      for (let i = 0; i < to.length; i++) {
        if (opts.metric === 'cost' && !from[i]!.hasValue) continue
        to[i]!.sum += from[i]!.sum
        to[i]!.hasValue = to[i]!.hasValue || from[i]!.hasValue
      }
    }
    outKeys = [...keep].sort()
    if (!keep.includes(mergeTarget)) outKeys.push(mergeTarget)
  }
  const out: Record<string, (number | null)[]> = Object.create(null)
  for (const g of outKeys) {
    out[g] = acc[g]!.map(c => (opts.metric === 'cost' ? (c.hasValue ? c.sum : null) : c.sum))
  }
  return { times, series: out, unit: opts.metric === 'cost' ? 'USD' : opts.metric === 'calls' ? 'calls' : 'tokens' }
}

export function overview(rows: UsageRow[]) {
  let totalTokens = 0, calls = 0, cacheRead = 0, freshInput = 0
  let cost = 0, costSeen = false, estimatedCost = 0
  const days = new Set<string>()
  // 无原型容器：键来自数据（host/tool 名），'constructor' 等名字不得命中继承属性
  const byHost: Record<string, { tokens: number; cost: number | null; calls: number }> = Object.create(null)
  const byTool: Record<string, { tokens: number; cost: number | null; calls: number }> = Object.create(null)
  const bump = (map: typeof byHost, key: string, r: UsageRow) => {
    const e = (map[key] ??= { tokens: 0, cost: null, calls: 0 })
    e.tokens += rowTokens(r)
    e.calls += 1
    if (r.cost !== null) { e.cost = (e.cost ?? 0) + r.cost }
  }
  for (const r of rows) {
    totalTokens += rowTokens(r); calls += 1
    cacheRead += r.tcacheRead; freshInput += r.tin
    if (r.cost !== null) {
      cost += r.cost; costSeen = true
      // 估算成本单独透出：未存储 costUSD / 标记 estimated 的行不能与实价混为一谈
      if (r.costEstimated) estimatedCost += r.cost
    }
    days.add(new Date(r.ts).toDateString())
    bump(byHost, r.host, r); bump(byTool, r.tool, r)
  }
  return {
    totalTokens, totalCost: costSeen ? cost : null, calls,
    cacheHitRate: freshInput + cacheRead > 0 ? cacheRead / (freshInput + cacheRead) : null,
    activeDays: days.size, byHost, byTool, estimatedCost,
  }
}

export function matrix(rows: UsageRow[], rowKey: Group, colKey: 'model') {
  const rowKeys = [...new Set(rows.map(r => groupValue(r, rowKey)))].sort()
  const colKeys = [...new Set(rows.map(r => r[colKey]))].sort()
  const ri = new Map(rowKeys.map((k, i) => [k, i])), ci = new Map(colKeys.map((k, i) => [k, i]))
  const values: (number | null)[][] = rowKeys.map(() => colKeys.map(() => null))
  for (const r of rows) {
    const i = ri.get(groupValue(r, rowKey))!, j = ci.get(r[colKey])!
    values[i]![j] = (values[i]![j] ?? 0) + rowTokens(r)
  }
  return { rowKeys, colKeys, values }
}

export function modelTable(rows: UsageRow[]) {
  // tokens = 每行按其所属工具口径（rowTokens）累加的总 token：同一模型可能来自
  // 多个工具（reasoning 口径不同），必须在行级去重后再合并，不能事后用单一工具重算
  const map = new Map<string, { model: string; calls: number; tokens: number; tin: number; tout: number; treason: number; tcacheRead: number; tcacheWrite: number; cost: number | null }>()
  for (const r of rows) {
    const e = map.get(r.model) ?? { model: r.model, calls: 0, tokens: 0, tin: 0, tout: 0, treason: 0, tcacheRead: 0, tcacheWrite: 0, cost: null }
    e.calls += 1; e.tokens += rowTokens(r)
    e.tin += r.tin; e.tout += r.tout; e.treason += r.treason; e.tcacheRead += r.tcacheRead; e.tcacheWrite += r.tcacheWrite
    if (r.cost !== null) e.cost = (e.cost ?? 0) + r.cost
    map.set(r.model, e)
  }
  // 排序键 = 展示口径的 token 总量，与「服务端已按 token 总量降序」一致
  return [...map.values()].sort((a, b) => b.tokens - a.tokens)
}
