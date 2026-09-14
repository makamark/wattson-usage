// web/src/main.ts — 组装：Sidebar 路由 + 顶栏控件 + 各区块渲染 + 全局联动 + 定时自刷。
// 路由 = hash → 一组区块的显隐与重渲（PAGES），不引入框架。
import './style.css'
import { initMainChart, renderMainChart, resizeMainChart } from './mainchart.js'
import { renderKpi } from './kpi.js'
import { renderPlan } from './plan.js'
import { renderFilters } from './filters.js'
import { renderMatrix } from './matrix.js'
import { renderModels } from './models.js'
import { renderHosts } from './hosts.js'
import { renderSettings } from './settings.js'
import { renderStatus, type StatusPayload } from './status.js'
import { api } from './api.js'
import { state, onChange, setFilters, clearDrilldown, type Filters } from './state.js'
import { fmtTime, esc } from './format.js'
import { renderSidebar, onRouteChange, currentRoute, type Route } from './nav.js'
import { icon } from './icons.js'

const RANGE_LABELS: Array<[Filters['range'], string]> = [
  ['today', '今日'], ['24h', '24 小时'], ['7d', '7 天'], ['30d', '30 天'], ['all', '全部'],
]
const METRIC_LABELS: Array<[Filters['metric'], string]> = [
  ['tokens', 'Token'], ['cost', '成本'], ['calls', '调用'],
]
const GROUP_SEGS: Array<[Filters['group'], string]> = [
  ['total', '总计'], ['model', '按模型'], ['host', '按设备'], ['tool', '按工具'],
]

type PageDef = { show: string[]; render: Array<() => Promise<unknown> | void> }
const PAGES: Record<Route, PageDef> = {
  overview: { show: ['kpi', 'filters', 'chart-card', 'plan'], render: [renderKpi, renderFilters, renderMainChart, renderPlan] },
  usage: { show: ['filters', 'matrix', 'models'], render: [renderFilters, renderMatrix, renderModels] },
  plans: { show: ['plan'], render: [renderPlan] },
  hosts: { show: ['hosts'], render: [renderHosts] },
  settings: { show: ['settings'], render: [renderSettings] },
}

function applyRoute(): void {
  const page = PAGES[currentRoute()]
  for (const el of document.querySelectorAll<HTMLElement>('.page-block')) el.hidden = true
  for (const id of page.show) (document.getElementById(id) as HTMLElement).hidden = false
}

// ---------- 顶栏 ----------
const topbar = document.getElementById('topbar')!

function renderTopbar(): void {
  const f = state.filters
  topbar.innerHTML = `
    <label class="ctl">
      ${icon('calendar', 14)}
      <select id="sel-range">${RANGE_LABELS.map(([v, label]) => `<option value="${v}" ${v === f.range ? 'selected' : ''}>${label}</option>`).join('')}</select>
    </label>
    <label class="ctl">
      ${icon('tokens', 14)}
      <select id="sel-metric">${METRIC_LABELS.map(([v, label]) => `<option value="${v}" ${v === f.metric ? 'selected' : ''}>${label}</option>`).join('')}</select>
    </label>
    <span id="fetched" title="最近一次成功采集时间"><i class="live-dot" aria-hidden="true"></i><span id="fetched-text"></span></span>
    <button id="btn-refresh" title="触发一次全量采集（后台执行，约数分钟后完成）">${icon('refresh', 14)}刷新</button>`
  ;(topbar.querySelector('#sel-range') as HTMLSelectElement).onchange = e => setFilters({ range: (e.target as HTMLSelectElement).value as Filters['range'] })
  ;(topbar.querySelector('#sel-metric') as HTMLSelectElement).onchange = e => setFilters({ metric: (e.target as HTMLSelectElement).value as Filters['metric'] })
  topbar.querySelector('#btn-refresh')!.addEventListener('click', () => {
    // 可感知反馈：立即显示采集状态，2.5s 后恢复（期间任何 renderAll 重建顶栏也会自然恢复）。
    const btn = topbar.querySelector('#btn-refresh') as HTMLButtonElement
    btn.classList.add('busy')
    btn.innerHTML = `${icon('refresh', 14)}采集中…`
    void api.refresh().finally(() => setTimeout(() => {
      btn.classList.remove('busy')
      btn.innerHTML = `${icon('refresh', 14)}刷新`
    }, 2500))
  })
}

/** 主图卡上的分段控件：总计/按模型/按设备/按工具（全局 group） */
function renderSegmented(): void {
  const seg = document.getElementById('chart-seg')
  if (!seg) return
  seg.innerHTML = GROUP_SEGS.map(([v, label]) =>
    `<button class="seg${v === state.filters.group ? ' on' : ''}" data-group="${v}">${label}</button>`).join('')
  seg.querySelectorAll<HTMLButtonElement>('.seg').forEach(b =>
    b.addEventListener('click', () => setFilters({ group: b.dataset.group as Filters['group'] })))
}

// API 失败集中展示在状态区（底部），不打断其它区块的渲染。
function showErrors(errs: string[]): void {
  if (!errs.length) return
  const el = document.getElementById('status')!
  el.innerHTML = `<span class="err">加载失败：${errs.map(e => esc(e)).join('；')}</span>` + el.innerHTML
}

let renderSeq = 0
async function renderAll(): Promise<void> {
  const seq = ++renderSeq
  renderTopbar()
  renderSegmented()
  const [status, ...rest] = await Promise.allSettled([renderStatus() as Promise<StatusPayload>, ...PAGES[currentRoute()].render.map(fn => fn())])
  if (seq !== renderSeq) return // 已有更新的渲染在途，丢弃本次结果
  const errs = [status, ...rest]
    .filter((r): r is PromiseRejectedResult => r.status === 'rejected')
    .map(r => r.reason instanceof Error ? r.reason.message : String(r.reason))
  if (status.status === 'fulfilled') {
    // 「数据时间」取最近一次成功采集时间（失败轮的 fetchedAt 不伪装成新数据）
    const st = status.value
    const text = document.getElementById('fetched-text')
    if (text) text.textContent = `数据 ${fmtTime(st.lastSuccessAt ?? st.fetchedAt)}`
  }
  showErrors(errs)
}

renderSidebar()
initMainChart()
onChange(() => void renderAll())
onRouteChange(() => { applyRoute(); resizeMainChart(); void renderAll() })
applyRoute()
await renderAll()
setInterval(() => void renderAll(), 5 * 60 * 1000)
