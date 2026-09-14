// web/src/hosts.ts — 设备页：每设备一张份额卡（token/成本/调用/占比条）+ 设备×时间堆叠图。
// 卡片数据来自 /api/overview 的 byHost（含 calls）；图表与主图共用 series 接口（group=host）。
import { api } from './api.js'
import { state, filterQuery } from './state.js'
import { fmtInt, fmtTokens, fmtCost, esc } from './format.js'
import { renderHostsChart } from './mainchart.js'

let renderSeq = 0

export async function renderHosts(): Promise<void> {
  const el = document.getElementById('hosts')!
  const seq = ++renderSeq
  const f = state.filters
  const o = await api.overview(filterQuery(f))
  if (seq !== renderSeq) return
  const hosts = (Object.entries(o.byHost ?? {}) as Array<[string, { tokens: number; cost: number | null; calls?: number }]>)
    .sort((a, b) => b[1].tokens - a[1].tokens)
  if (!hosts.length) { el.innerHTML = '<p class="empty">暂无设备数据</p>'; return }
  const total = hosts.reduce((s, [, v]) => s + v.tokens, 0) || 1
  const metricLabel = f.metric === 'tokens' ? 'Token' : f.metric === 'cost' ? '成本' : '调用'
  el.innerHTML = `
    <div class="hosts-grid">
      ${hosts.map(([name, v]) => {
        const share = v.tokens / total * 100
        return `<div class="card host-card">
          <div class="host-head"><span class="host-dot" aria-hidden="true"></span><span class="host-name" title="${esc(name)}">${esc(name)}</span><span class="host-share">${share.toFixed(1)}%</span></div>
          <div class="host-value">${fmtTokens(v.tokens)}</div>
          <div class="host-sub">${fmtCost(v.cost)} · ${fmtInt(Number(v.calls ?? 0))} 次调用</div>
          <div class="host-bar"><i style="width:${share.toFixed(1)}%"></i></div>
        </div>`
      }).join('')}
    </div>
    <div class="card-block hosts-chart-wrap">
      <div class="card-head"><h3>设备 × 时间（${metricLabel}）</h3></div>
      <div id="hosts-chart"></div>
    </div>`
  await renderHostsChart()
}
