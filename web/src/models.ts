// web/src/models.ts — 模型明细表（服务端已按 token 总量降序，查询带统一筛选）。
import { api } from './api.js'
import { fmtInt, fmtTokens, fmtCost, esc } from './format.js'
import { state, filterQuery } from './state.js'

// 请求序号：晚到的陈旧响应不得覆盖新数据。
let renderSeq = 0

export async function renderModels(): Promise<void> {
  const el = document.getElementById('models')!
  const seq = ++renderSeq
  const f = state.filters
  const rows = await api.models(filterQuery(f))
  if (seq !== renderSeq) return // 已有更新的请求，丢弃本次结果
  if (!rows?.length) { el.innerHTML = '<h3>模型明细</h3><p class="empty">暂无数据</p>'; return }
  el.innerHTML = `<h3>模型明细</h3><table><tr><th>模型</th><th>调用</th><th>输入</th><th>输出</th><th>推理</th><th>缓存读</th><th>缓存写</th><th>成本</th></tr>
    ${rows.map((r: any) => `<tr><td title="${esc(r.model)}">${esc(r.model)}</td><td>${fmtInt(Number(r.calls))}</td><td>${fmtTokens(r.tin)}</td><td>${fmtTokens(r.tout)}</td><td>${fmtTokens(r.treason)}</td><td>${fmtTokens(r.tcacheRead)}</td><td>${fmtTokens(r.tcacheWrite)}</td><td>${fmtCost(r.cost)}</td></tr>`).join('')}</table>`
}
