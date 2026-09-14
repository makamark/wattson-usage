// web/src/mainchart.ts — ECharts 堆叠柱状主图（卡内分段控件切维度）。
// 维度（group）× 指标（metric）× 时间窗（range）来自全局 state；
// 图例点选状态在每次重渲时从当前 option 捕获并回传（notMerge 会整体替换 option，
// 否则用户的图例开/关选择会被重置）。单一系列（group=total）不显示图例。
import * as echarts from 'echarts'
import { api } from './api.js'
import { state, filterQuery } from './state.js'
import { fmtInt, fmtTokens, fmtCost, esc } from './format.js'

let chart: echarts.ECharts | null = null
// 请求序号：慢请求（range=all）晚于快请求返回时丢弃过期结果，避免图表回跳。
let renderSeq = 0

const PALETTE = ['#57a48f', '#d9c589', '#c97b5d', '#7f98a8', '#8fa76f', '#e0a458', '#6fa8a0', '#b9c0ae']

export function initMainChart(): void {
  chart = echarts.init(document.getElementById('mainchart')!)
  window.addEventListener('resize', () => { chart?.resize(); hostsChart?.resize() })
}

export function resizeMainChart(): void {
  // 从隐藏容器切回时 ECharts 尺寸为 0，需显式 resize
  chart?.resize()
  hostsChart?.resize()
}

function axisFmt(metric: string): (v: number) => string {
  if (metric === 'cost') return v => '$' + fmtTokens(v)
  if (metric === 'calls') return fmtInt
  return fmtTokens
}

function valueFmt(metric: string): (v: number) => string {
  if (metric === 'cost') return fmtCost
  if (metric === 'calls') return fmtInt
  return fmtTokens
}

// 悬浮明细：只列该时间点有量（非 0、非 null）的系列，按用量降序；
// 全部为 0 时返回空串（不弹 tooltip）。系列名来自数据，需 esc 转义。
function tooltipHtml(params: unknown, metric: string): string {
  const arr = Array.isArray(params) ? params : [params]
  const rows: Array<{ marker: string; name: string; value: number }> = []
  let label = ''
  for (const p of arr as Array<Record<string, unknown>>) {
    label = String(p.axisValueLabel ?? p.name ?? '')
    const v = Array.isArray(p.value) ? p.value[p.value.length - 1] : p.value
    if (typeof v === 'number' && v !== 0) {
      rows.push({ marker: String(p.marker ?? ''), name: String(p.seriesName ?? ''), value: v })
    }
  }
  if (rows.length === 0) return ''
  rows.sort((a, b) => b.value - a.value)
  const fmt = valueFmt(metric)
  const total = rows.reduce((s, r) => s + r.value, 0)
  const lines = rows.map(r => `${r.marker} ${esc(r.name)}&nbsp;&nbsp;${fmt(r.value)}`).join('<br/>')
  return `<div style="max-height:320px;overflow:auto">${esc(label)}<br/>${lines}` +
    (rows.length > 1 ? `<br/><b>合计 ${fmt(total)}</b>` : '') + '</div>'
}

function hourly(range: string): boolean {
  return range === '24h' || range === 'today'
}

export async function renderMainChart(): Promise<void> {
  if (!chart) return
  chart.resize() // 容器可能刚从 hidden 恢复（init 时为 0 尺寸），渲染前先校准
  const seq = ++renderSeq
  const f = state.filters
  // 统一筛选：维度钻取（hosts/tools/…）也下推到服务端过滤，主图与 KPI 口径一致
  const data = await api.series({ bucket: hourly(f.range) ? 'hour' : 'day', group: f.group, metric: f.metric, ...filterQuery(f) })
  if (seq !== renderSeq) return // 已有更新的请求，丢弃本次结果
  // 捕获用户当前的图例开/关选择（首次渲染前 getOption 为空则跳过），
  // 经 option 传回；group 切换后不在新 series 中的名字会被 ECharts 忽略。
  const prev = chart.getOption() as unknown as { legend?: Array<{ selected?: Record<string, boolean> }> } | undefined
  const legendSelected = prev?.legend?.[0]?.selected
  const single = Object.keys(data.series).length <= 1
  const hourTicks = hourly(f.range)
  chart.setOption({
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'shadow' },
      backgroundColor: '#2a3134', borderColor: 'rgba(250,248,241,0.12)',
      textStyle: { color: '#ece9df', fontSize: 12 },
      formatter: (params: unknown) => tooltipHtml(params, f.metric),
    },
    legend: single ? { show: false } : {
      top: 4, left: 8, right: 8, type: 'scroll', icon: 'circle',
      textStyle: { color: '#a3aca6' }, inactiveColor: '#525b58', pageIconColor: '#a3aca6', pageTextStyle: { color: '#a3aca6' },
      ...(legendSelected ? { selected: legendSelected } : {}),
    },
    grid: { left: 60, right: 16, top: single ? 16 : 34, bottom: 28 },
    xAxis: {
      type: 'category',
      data: data.times.map((t: number) => new Date(t).toLocaleString('zh-CN',
        hourTicks ? { month: '2-digit', day: '2-digit', hour: '2-digit', hour12: false } : { month: '2-digit', day: '2-digit' })),
      axisLabel: { color: '#a3aca6', hideOverlap: true },
      axisLine: { lineStyle: { color: 'rgba(250,248,241,0.12)' } },
      axisTick: { show: false },
    },
    yAxis: {
      type: 'value',
      axisLabel: { color: '#a3aca6', formatter: axisFmt(f.metric) },
      splitLine: { lineStyle: { color: 'rgba(250,248,241,0.06)' } },
    },
    series: Object.entries(data.series as Record<string, (number | null)[]>).map(([name, values], i) => ({
      name,
      type: 'bar',
      stack: 'total',
      barMaxWidth: 28,
      emphasis: { focus: 'series' },
      itemStyle: { color: PALETTE[i % PALETTE.length], borderRadius: single ? [6, 6, 0, 0] : 2 },
      data: values,
    })),
  }, { notMerge: true })
}

// ---------- 设备页的 设备×时间 图（复用同一套视觉参数） ----------
let hostsChart: echarts.ECharts | null = null

export async function renderHostsChart(): Promise<void> {
  const dom = document.getElementById('hosts-chart')
  if (!dom) return
  const seq = ++renderSeq
  const f = state.filters
  const data = await api.series({ bucket: hourly(f.range) ? 'hour' : 'day', group: 'host', metric: f.metric, ...filterQuery(f) })
  if (seq !== renderSeq) return
  hostsChart = echarts.getInstanceByDom(dom) ?? echarts.init(dom)
  hostsChart.resize()
  const single = Object.keys(data.series).length <= 1
  hostsChart.setOption({
    tooltip: {
      trigger: 'axis', axisPointer: { type: 'shadow' },
      backgroundColor: '#2a3134', borderColor: 'rgba(250,248,241,0.12)',
      textStyle: { color: '#ece9df', fontSize: 12 },
      formatter: (params: unknown) => tooltipHtml(params, f.metric),
    },
    legend: single ? { show: false } : {
      top: 4, left: 8, right: 8, type: 'scroll', icon: 'circle',
      textStyle: { color: '#a3aca6' }, inactiveColor: '#525b58', pageIconColor: '#a3aca6', pageTextStyle: { color: '#a3aca6' },
    },
    grid: { left: 60, right: 16, top: single ? 16 : 34, bottom: 28 },
    xAxis: {
      type: 'category',
      data: data.times.map((t: number) => new Date(t).toLocaleString('zh-CN',
        hourly(f.range) ? { month: '2-digit', day: '2-digit', hour: '2-digit', hour12: false } : { month: '2-digit', day: '2-digit' })),
      axisLabel: { color: '#a3aca6', hideOverlap: true },
      axisLine: { lineStyle: { color: 'rgba(250,248,241,0.12)' } },
      axisTick: { show: false },
    },
    yAxis: {
      type: 'value',
      axisLabel: { color: '#a3aca6', formatter: axisFmt(f.metric) },
      splitLine: { lineStyle: { color: 'rgba(250,248,241,0.06)' } },
    },
    series: Object.entries(data.series as Record<string, (number | null)[]>).map(([name, values], i) => ({
      name, type: 'bar', stack: 'total', barMaxWidth: 28,
      emphasis: { focus: 'series' },
      itemStyle: { color: PALETTE[i % PALETTE.length] },
      data: values,
    })),
  }, { notMerge: true })
}
