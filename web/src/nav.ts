// web/src/nav.ts — 左侧 Sidebar + hash 路由。
// 页面 = 路由到一组区块元素的显隐 + 重渲（见 main.ts PAGES）；不引入框架，
// hashchange 驱动，刷新/直链都能落在正确页签。
import { icon } from './icons.js'
import { esc } from './format.js'

export type Route = 'overview' | 'usage' | 'plans' | 'hosts' | 'settings'

const ITEMS: Array<{ id: Route; label: string; icon: string }> = [
  { id: 'overview', label: '总览', icon: 'home' },
  { id: 'usage', label: '用量', icon: 'chart' },
  { id: 'plans', label: '额度', icon: 'layers' },
  { id: 'hosts', label: '设备', icon: 'monitor' },
  { id: 'settings', label: '设置', icon: 'settings' },
]

export function currentRoute(): Route {
  const h = location.hash.replace(/^#\/?/, '')
  return (ITEMS.some(i => i.id === h) ? h : 'overview') as Route
}

export function renderSidebar(): void {
  const el = document.getElementById('sidebar')!
  const cur = currentRoute()
  el.innerHTML = `
    <div class="side-brand">
      <span class="brand-mark"><svg width="17" height="17" viewBox="0 0 24 24" aria-hidden="true"><rect width="24" height="24" rx="5.5" fill="#2b3032"/><rect x="2.6" y="2.6" width="18.8" height="18.8" rx="4.2" fill="#f2efe6"/><path d="M6.4 14.4a5.6 5.6 0 0 1 11.2 0" stroke="#303638" stroke-width="1.6" fill="none" stroke-linecap="round"/><path d="M13.9 14.4l3-3.2" stroke="#57a48f" stroke-width="1.7" stroke-linecap="round"/><circle cx="12" cy="14.4" r="1.7" fill="#303638"/><circle cx="12" cy="14.4" r="0.6" fill="#f2efe6"/></svg></span>
      <div class="brand-text">
        <b>Wattson</b>
        <span>看懂你的 AI 用量</span>
      </div>
    </div>
    <nav class="side-nav">
      ${ITEMS.map(i => `
        <a class="side-item${i.id === cur ? ' active' : ''}" href="#${i.id}" data-route="${i.id}">
          ${icon(i.icon)}<span>${esc(i.label)}</span>
        </a>`).join('')}
    </nav>
    <div class="side-foot">更清楚地用 AI<br>迎接更有产出的明天</div>`
}

export function onRouteChange(fn: (r: Route) => void): void {
  window.addEventListener('hashchange', () => {
    renderSidebar() // 高亮随路由刷新
    fn(currentRoute())
  })
}
