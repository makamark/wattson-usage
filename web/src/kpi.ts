// web/src/kpi.ts — 指标卡（Token 总量/估算成本/调用次数/缓存命中率/活跃天数）。
// 主值来自带统一筛选的 /api/overview；compare=previous 附带上一等长窗口的 KPI，
// 卡片渲染环比箭头（命中率按百分点差、活跃天数按天数差，其余按百分比变化）。
// allTime 小字仍为「全时段、不过滤」口径（卡片上明确标注）。
import { api } from './api.js'
import { state, filterQuery } from './state.js'
import { fmtInt, fmtTokens, fmtCost } from './format.js'
import { icon } from './icons.js'

const CARDS = [
  { key: 'totalTokens', label: 'Token 总量', ic: 'tokens', fmt: (v: any) => fmtTokens(Number(v)) },
  { key: 'totalCost', label: '估算成本', ic: 'cost', fmt: (v: any) => fmtCost(v) },
  { key: 'calls', label: '调用次数', ic: 'calls', fmt: (v: any) => fmtInt(Number(v)) },
  { key: 'cacheHitRate', label: '缓存命中率', ic: 'zap', fmt: (v: any) => v == null ? '—' : (v * 100).toFixed(1) + '%' },
  { key: 'activeDays', label: '活跃天数', ic: 'calendar', fmt: (v: any) => fmtInt(Number(v)) },
] as const

/** 环比展示：无上一窗口/上一窗口为 0 时不显示箭头；命中率用百分点差（pp） */
function deltaHtml(key: string, cur: any, prev: any): string {
  if (!prev || prev[key] == null || cur[key] == null) return ''
  if (key === 'cacheHitRate') {
    const diff = (cur[key] - prev[key]) * 100
    if (!Number.isFinite(diff) || Math.abs(diff) < 0.05) return ''
    const up = diff > 0
    return `<span class="delta ${up ? 'up' : 'down'}">${up ? '↑' : '↓'} ${Math.abs(diff).toFixed(1)}pp</span>`
  }
  if (key === 'activeDays') {
    const diff = Number(cur[key]) - Number(prev[key])
    if (diff === 0) return ''
    return `<span class="delta ${diff > 0 ? 'up' : 'down'}">${diff > 0 ? '↑' : '↓'} ${Math.abs(diff)} 天</span>`
  }
  const p = Number(prev[key])
  if (p <= 0) return ''
  const pct = (Number(cur[key]) - p) / p * 100
  if (!Number.isFinite(pct) || Math.abs(pct) < 0.5) return ''
  const up = pct > 0
  return `<span class="delta ${up ? 'up' : 'down'}">${up ? '↑' : '↓'} ${Math.abs(pct).toFixed(pct > -10 && pct < 10 ? 1 : 0)}%</span>`
}

// 请求序号：晚到的陈旧响应不得覆盖新筛选下的指标卡。
let renderSeq = 0

export async function renderKpi(): Promise<void> {
  const el = document.getElementById('kpi')!
  const seq = ++renderSeq
  // 先取 filters 再 await：请求的查询条件与 renderSeq 守卫针对同一份筛选状态。
  const f = state.filters
  const o = await api.overview({ ...filterQuery(f), compare: 'previous' })
  if (seq !== renderSeq) return // 已有更新的请求，丢弃本次结果
  el.innerHTML = `<div class="kpi-grid">${CARDS.map(c => {
    const delta = deltaHtml(c.key, o, o.prev)
    return `
    <div class="card kpi-card" data-kpi="${c.key}">
      <div class="kpi-top"><span class="kpi-icon">${icon(c.ic, 15)}</span><span class="kpi-label">${c.label}</span></div>
      <div class="kpi-value">${c.fmt(o[c.key])}</div>
      <div class="kpi-foot">
        ${delta ? delta + '<span class="delta-cap">vs 上一周期</span>' : ''}
        ${f.range !== 'all' ? `<span class="card-sub">全时段 ${c.fmt(o.allTime[c.key])}</span>` : ''}
      </div>
    </div>`
  }).join('')}</div>`
}
