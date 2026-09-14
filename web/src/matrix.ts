// web/src/matrix.ts — 行 × model 的 token 热力矩阵。
// 无钻取时行=host（几行 × 几十列，横向滚动）；有 host/tool 钻取时行切到 model，
// 突出「选中来源内部各模型的分布」（brief 约定的 v1 行为）。
// 查询带统一筛选（range+hosts/tools/…），与 KPI/主图口径一致。
import { api } from './api.js'
import { fmtTokens, esc } from './format.js'
import { state, filterQuery } from './state.js'

// 请求序号：rowsKey 随 filters 变化，晚到的陈旧响应不得覆盖新数据。
let renderSeq = 0

export async function renderMatrix(): Promise<void> {
  const el = document.getElementById('matrix')!
  const seq = ++renderSeq
  const f = state.filters
  const rowsKey = f.hosts.length || f.tools.length ? 'model' : 'host'
  const m = await api.matrix({ rows: rowsKey, ...filterQuery(f) })
  if (seq !== renderSeq) return // 已有更新的请求，丢弃本次结果
  if (!m.rowKeys?.length) { el.innerHTML = '<h3>矩阵</h3><p class="empty">暂无数据</p>'; return }
  const max = Math.max(...(m.values as (number | null)[][]).flat().map(v => v ?? 0), 1)
  el.innerHTML = `<h3>矩阵（${rowsKey} × model，token）</h3><table class="matrix"><tr><th></th>${(m.colKeys as string[]).map(c => `<th title="${esc(c)}">${esc(c)}</th>`).join('')}</tr>
    ${m.rowKeys.map((r: string, i: number) => `<tr><th title="${esc(r)}">${esc(r)}</th>${m.colKeys.map((c: string, j: number) => {
      const v = m.values[i]![j]
      const alpha = v ? 0.08 + 0.85 * (v / max) : 0
      return `<td style="background:rgba(87,164,143,${alpha.toFixed(2)})">${v ? fmtTokens(v) : ''}</td>`
    }).join('')}</tr>`).join('')}</table>`
}
