// web/src/filters.ts — 钻取筛选条（按设备 / 按工具）。
// 精简呈现：单行 chip 条，位于订阅额度下方；chip = 名称+用量小字，
// 选中态高亮勾选。数值 = /api/overview 分面口径（byHost 忽略 hosts 过滤、
// byTool 忽略 tools 过滤，选中后其余条目仍可见可切换）。
import { api } from './api.js'
import { state, setFilters, toggle, filterQuery } from './state.js'
import { fmtTokens, esc } from './format.js'

let renderSeq = 0

interface FacetEntry { tokens: number }

// 工具名 → 官方 logo（与 plan.ts 的 LOGOS 同一套本地化文件）
const TOOL_LOGOS: Record<string, string> = {
  zcode: 'zai.svg', glm: 'zai.svg', codex: 'openai.svg', claude: 'claude.svg',
  cursor: 'cursor.svg', workbuddy: 'codebuddy.svg', trae: 'trae.svg',
}

function chipHtml(facet: 'hosts' | 'tools', name: string, tokens: number, on: boolean): string {
  const logo = facet === 'tools' ? TOOL_LOGOS[name] : undefined
  return `<button class="filter-chip${on ? ' on' : ''}" data-facet="${facet}" data-name="${esc(name)}"
    title="${esc(name)} · ${fmtTokens(tokens)}（点击${on ? '取消' : ''}筛选）">
    ${logo
    ? `<img class="chip-logo" src="/logos/${logo}" alt="" width="12" height="12" />`
    : '<span class="filter-dot" aria-hidden="true"></span>'}${esc(name)}<span class="filter-chip-value">${fmtTokens(tokens)}</span>
  </button>`
}

export async function renderFilters(): Promise<void> {
  const el = document.getElementById('filters')!
  const seq = ++renderSeq
  const f = state.filters
  const o = await api.overview(filterQuery(f))
  if (seq !== renderSeq) return
  const hosts = (Object.entries(o.byHost ?? {}) as Array<[string, FacetEntry]>)
    .sort((a, b) => b[1].tokens - a[1].tokens)
  const tools = (Object.entries(o.byTool ?? {}) as Array<[string, FacetEntry]>)
    .sort((a, b) => b[1].tokens - a[1].tokens)
  const active = f.hosts.length + f.tools.length > 0
  if (!hosts.length && !tools.length) { el.innerHTML = ''; return }
  el.innerHTML = `<div class="filter-bar">
    ${hosts.length ? `<span class="filter-bar-label">设备</span>${hosts.map(([name, v]) => chipHtml('hosts', name, v.tokens, f.hosts.includes(name))).join('')}` : ''}
    ${hosts.length && tools.length ? '<span class="filter-sep"></span><span class="filter-bar-label">工具</span>' : ''}
    ${tools.map(([name, v]) => chipHtml('tools', name, v.tokens, f.tools.includes(name))).join('')}
    ${active ? '<button id="filter-clear" class="filter-clear" title="清除全部钻取筛选">清除</button>' : ''}
  </div>`
  el.querySelectorAll<HTMLButtonElement>('.filter-chip').forEach(b => {
    b.addEventListener('click', () => {
      const facet = b.dataset.facet as 'hosts' | 'tools'
      const name = b.dataset.name!
      setFilters({ [facet]: toggle(state.filters[facet], name) } as Partial<typeof state.filters>)
    })
  })
  el.querySelector('#filter-clear')?.addEventListener('click', () => setFilters({ hosts: [], tools: [] }))
}
