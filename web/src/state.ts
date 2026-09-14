// web/src/state.ts — 全局联动核心：单一 filters 对象 + 订阅通知。
// 任何区块改动 filters 后，main.ts 的 renderAll 会被触发重绘。
export type Filters = {
  range: '24h' | 'today' | '7d' | '30d' | 'all'
  hosts: string[]
  tools: string[]
  models: string[]
  projects: string[]
  metric: 'tokens' | 'cost' | 'calls'
  group: 'total' | 'host' | 'tool' | 'model' | 'project'
}

const initial: Filters = {
  range: '30d', hosts: [], tools: [], models: [], projects: [],
  metric: 'tokens', group: 'model',
}

export const state = { filters: initial, listeners: new Set<() => void>() }

export function setFilters(patch: Partial<Filters>): void {
  state.filters = { ...state.filters, ...patch }
  state.listeners.forEach(fn => fn())
}

export function onChange(fn: () => void): void {
  state.listeners.add(fn)
}

export function toggle(list: string[], v: string): string[] {
  return list.includes(v) ? list.filter(x => x !== v) : [...list, v]
}

export function clearDrilldown(): void {
  setFilters({ hosts: [], tools: [], models: [], projects: [] })
}

// 统一查询条件 → /api 查询串：所有区块（KPI/主图/矩阵/模型表）都带同一份
// range + 维度过滤，服务端先过滤再聚合，保证各区块口径一致。
export function filterQuery(f: Filters): Record<string, string> {
  const q: Record<string, string> = { range: f.range }
  if (f.hosts.length) q['hosts'] = f.hosts.join(',')
  if (f.tools.length) q['tools'] = f.tools.join(',')
  if (f.models.length) q['models'] = f.models.join(',')
  if (f.projects.length) q['projects'] = f.projects.join(',')
  return q
}
