// server/src/api.ts — pure routing over a Snapshot: no I/O, no server state,
// so the route table is trivially testable (see tests/api.test.ts).
// 所有聚合路由共享同一套查询条件（range/hosts/tools/models/projects）：先 filterRows
// 再聚合，保证 KPI/主图/矩阵/模型表对「点选钻取 + 时间范围」语义一致；
// 刻意不过滤的口径（overview.allTime）在响应里单独命名，不与主值混用。
import {
  overview, series, matrix, modelTable, filterRows,
  type Bucket, type Group, type Metric, type RowFilter, type UsageRow,
} from './aggregate.js'
import type { Snapshot } from './collector.js'
import type { QuotaSnapshot } from './quotas/types.js'

// today 为动态窗口（本地零点起）：rangeMs 逐请求计算，不在常量表里
const RANGES: Record<string, number | null> = { '24h': 24 * 3600e3, '7d': 7 * 24 * 3600e3, '30d': 30 * 24 * 3600e3, all: null }
const BUCKETS: Bucket[] = ['day', 'hour']
const GROUPS: Group[] = ['total', 'host', 'tool', 'model', 'project']
const METRICS: Metric[] = ['tokens', 'cost', 'calls']
// 资源边界：分组数超 Top-N 合并为「其他」；时间桶数超上限只保留最近窗口
const MAX_SERIES = 12
const MAX_BUCKETS = 400

type ApiResult = { status: number; body: unknown }

/** 环比用的 KPI 子集（与看板 KPI 卡一一对应） */
type KpiPrev = { totalTokens: number; totalCost: number | null; calls: number; cacheHitRate: number | null; activeDays: number }
const slimKpi = (o: ReturnType<typeof overview>): KpiPrev => ({
  totalTokens: o.totalTokens, totalCost: o.totalCost, calls: o.calls,
  cacheHitRate: o.cacheHitRate, activeDays: o.activeDays,
})

/** 解析范围参数为窗口长度（ms）；today = 本地零点至今。返回字符串为 400 错误消息 */
function rangeMs(rangeRaw: string, now: number): number | null | string {
  if (rangeRaw === 'today') {
    const d = new Date(now)
    d.setHours(0, 0, 0, 0)
    return now - d.getTime()
  }
  if (Object.hasOwn(RANGES, rangeRaw)) return RANGES[rangeRaw]!
  return `未知范围: ${rangeRaw}（可选 24h/today/7d/30d/all）`
}

/** 解析统一筛选参数；返回值是字符串时为 400 错误消息 */
function parseFilterQuery(url: URL, now: number): RowFilter | string {
  const r = rangeMs(url.searchParams.get('range') ?? 'all', now)
  if (typeof r === 'string') return r
  const csv = (name: string): string[] =>
    (url.searchParams.get(name) ?? '').split(',').map(s => s.trim()).filter(Boolean)
  return {
    rangeMs: r,
    hosts: csv('hosts'), tools: csv('tools'), models: csv('models'), projects: csv('projects'),
  }
}

const fail = (error: string): ApiResult => ({ status: 400, body: { error } })

// 聚合结果按「rows 数组身份 + 查询串」缓存：rows 在每次 refresh 时整体替换，
// 同一快照内页面一次渲染的多个区块/多次自刷可直接复用，避免每请求全量重扫。
const bodyCache = new WeakMap<UsageRow[], Map<string, unknown>>()
function cachedBody(rows: UsageRow[], key: string, compute: () => unknown): ApiResult {
  let m = bodyCache.get(rows)
  if (!m) { m = new Map(); bodyCache.set(rows, m) }
  const hit = m.get(key)
  if (hit !== undefined) return { status: 200, body: hit }
  if (m.size >= 200) m.clear()
  const body = compute()
  m.set(key, body)
  return { status: 200, body }
}

export function handleApi(url: URL, snap: Snapshot, localHost: string, handshake?: Record<string, unknown>, plan?: QuotaSnapshot | null): ApiResult {
  const rows = snap.rows
  const path = url.pathname
  if (path === '/api/overview') {
    const now = Date.now()
    const f = parseFilterQuery(url, now)
    if (typeof f === 'string') return fail(f)
    const compare = url.searchParams.get('compare') ?? ''
    if (compare && compare !== 'previous') return fail(`未知 compare: ${compare}（可选 previous）`)
    return cachedBody(rows, path + url.search, () => {
      const scoped = overview(filterRows(rows, f, now))
      // 分面口径：byHost 忽略 hosts 过滤、byTool 忽略 tools 过滤（其余条件生效），
      // 让「按设备/按工具」钻取按钮在已选 filtr 下仍可见可选
      const byHost = overview(filterRows(rows, { ...f, hosts: [] }, now)).byHost
      const byTool = overview(filterRows(rows, { ...f, tools: [] }, now)).byTool
      // compare=previous：对上一等长窗口再跑一次同一聚合（[now-2N, now-N)）。
      // filterRows 只裁旧边，上边界的当前窗口行需显式剔除。
      const prev = compare === 'previous' && f.rangeMs !== null
        ? slimKpi(overview(filterRows(rows, f, now - f.rangeMs).filter(r => r.ts < now - f.rangeMs!)))
        : null
      return {
        ...scoped, byHost, byTool,
        // allTime = 每行全量、不过任何滤（刻意全历史的旁注口径，含 estimatedCost）
        allTime: overview(rows),
        prev,
        fetchedAt: snap.fetchedAt, lastSuccessAt: snap.lastSuccessAt, errors: snap.errors,
      }
    })
  }
  if (path === '/api/series') {
    const bucket = url.searchParams.get('bucket') ?? 'day'
    if (!BUCKETS.includes(bucket as Bucket)) return fail(`未知 bucket: ${bucket}（可选 day/hour）`)
    const group = url.searchParams.get('group') ?? 'model'
    if (!GROUPS.includes(group as Group)) return fail(`未知 group: ${group}（可选 total/host/tool/model/project）`)
    const metric = url.searchParams.get('metric') ?? 'tokens'
    if (!METRICS.includes(metric as Metric)) return fail(`未知 metric: ${metric}（可选 tokens/cost/calls）`)
    const now = Date.now()
    const f = parseFilterQuery(url, now)
    if (typeof f === 'string') return fail(f)
    return cachedBody(rows, path + url.search, () =>
      series(filterRows(rows, f, now), { bucket: bucket as Bucket, group: group as Group, rangeMs: null, metric: metric as Metric, now, maxSeries: MAX_SERIES, maxBuckets: MAX_BUCKETS }))
  }
  if (path === '/api/matrix') {
    const rowKey = url.searchParams.get('rows') ?? 'host'
    if (!GROUPS.includes(rowKey as Group)) return fail(`未知 rows: ${rowKey}（可选 total/host/tool/model/project）`)
    const now = Date.now()
    const f = parseFilterQuery(url, now)
    if (typeof f === 'string') return fail(f)
    return cachedBody(rows, path + url.search, () => matrix(filterRows(rows, f, now), rowKey as Group, 'model'))
  }
  if (path === '/api/models') {
    const now = Date.now()
    const f = parseFilterQuery(url, now)
    if (typeof f === 'string') return fail(f)
    return cachedBody(rows, path + url.search, () => modelTable(filterRows(rows, f, now)))
  }
  if (path === '/api/plan') {
    // 订阅账号额度（GLM/Codex/Claude/Cursor/WorkBuddy/Trae），入口进程后台轮询注入。
    // 只回传额度数据，凭据永不出服务端。未初始化时给 loading 态而不是 404。
    return { status: 200, body: plan ?? { accounts: [] } }
  }
  if (path === '/api/status') {
    // handshake：入口进程注入的实例身份（configPath/instanceId…），客户端接管
    // 外部实例前据此核对配置来源，避免「端口通但配置不同源」的静默错配
    return { status: 200, body: { localHost, fetchedAt: snap.fetchedAt, lastSuccessAt: snap.lastSuccessAt, refreshing: snap.refreshing, errors: snap.errors, recordCount: rows.length, ...handshake } }
  }
  return { status: 404, body: { error: 'not found' } }
}
