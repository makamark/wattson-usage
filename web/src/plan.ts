// web/src/plan.ts — 订阅额度区块（GLM / Codex / Claude / Cursor / WorkBuddy / Trae）。
// 数据来自 /api/plan（server 后台轮询各官方接口，凭据不出服务端）。
// 每个有凭据的账号一张卡：品牌色标 + 套餐徽标 + 各窗口条（短标签/进度/百分比·绝对值·重置倒计时）；
// 无凭据/加载中隐藏，失败只显示一行原因。
import { getJson } from './api.js'
import { fmtInt, fmtTime, esc } from './format.js'
import { icon } from './icons.js'

export interface QuotaWindow {
  key: string
  label: string
  usedPercent?: number | null
  total?: number | null
  used?: number | null
  remaining?: number | null
  percentage: number | null
  nextResetAt: number | null
}

export interface QuotaAccount {
  kind: string
  label: string
  available: boolean
  unavailableReason: string | null
  error: string | null
  planName: string | null
  windows: QuotaWindow[]
  /** 额度重置卡张数（codex），无此概念为 null */
  resetCredits?: number | null
  /** 当前额度状态下可用的重置卡张数（codex），无此概念为 null */
  applicableResetCredits?: number | null
  fetchedAt: number
  lastSuccessAt: number | null
}

export interface QuotaSnapshot { accounts: QuotaAccount[] }

// kind → 官方 logo（LobeHub 开源图标库 @lobehub/icons-static-svg，本地化到 /logos/）
const LOGOS: Record<string, string> = {
  glm: 'zai.svg', codex: 'openai.svg', claude: 'claude.svg',
  cursor: 'cursor.svg', workbuddy: 'codebuddy.svg', trae: 'trae.svg',
}

let renderSeq = 0

/** 窗口短标签（w.label 是「5 小时窗口」这类长名，卡内用短名省宽度） */
const WINDOW_SHORT: Record<string, string> = {
  fiveHour: '5小时', week: '周', weekSonnet: '周·Sonnet', extra: '额外', cycle: '周期',
}

const KIND_SHORT: Record<string, string> = {
  glm: 'GLM', codex: 'Codex', claude: 'Claude', cursor: 'Cursor', workbuddy: 'WorkBuddy', trae: 'Trae',
}

function fmtReset(ms: number | null): string {
  if (!ms) return ''
  const delta = ms - Date.now()
  if (delta <= 0) return '已可重置'
  const d = Math.floor(delta / 86400e3)
  const h = Math.floor((delta % 86400e3) / 3600e3)
  const m = Math.round((delta % 3600e3) / 60e3)
  return d > 0 ? `${d}天${h}时` : h > 0 ? `${h}h${m}m` : `${m}m`
}

function windowRow(w: QuotaWindow): string {
  const hasAbs = typeof w.total === 'number' && w.total !== null
  // 剩余口径（对齐订阅产品官方展示，如 zcode「剩余 66%」）：
  // 绝对值口径由 remaining/total 直接算并向上取整（同官方 zcode 的取整方式），
  // 纯百分比口径（codex 等）用 100 - 已用%；已用细节放悬浮提示。
  const remainingAbs = hasAbs ? (w.remaining ?? Math.max(0, (w.total ?? 0) - (w.used ?? 0))) : null
  const remainPct = remainingAbs !== null && (w.total ?? 0) > 0
    ? Math.ceil(Math.min(100, Math.max(0, remainingAbs / (w.total ?? 1) * 100)))
    : 100 - Math.min(100, Math.max(0, w.percentage ?? w.usedPercent ?? 0))
  const hot = remainPct <= 10 ? 'var(--err)' : remainPct <= 30 ? 'var(--warn)' : 'var(--accent)'
  const reset = fmtReset(w.nextResetAt)
  const nums = remainingAbs !== null
    ? `剩 ${remainPct}% · ${fmtInt(remainingAbs)}/${fmtInt(w.total ?? 0)}`
    : `剩 ${remainPct}%`
  const tip = `${esc(w.label)}：剩 ${remainPct}%${hasAbs ? ` · 已用 ${fmtInt(w.used ?? 0)}/${fmtInt(w.total ?? 0)}` : ''}${reset ? ` · ${reset}后重置` : ''}`
  return `<div class="plan-window" title="${tip}">
    <span class="pw-label">${esc(WINDOW_SHORT[w.key] ?? w.label)}</span>
    <span class="pw-bar"><i style="width:${Math.min(100, Math.max(0, remainPct)).toFixed(1)}%;background:${hot}"></i></span>
    <span class="pw-nums">${nums}${reset ? `<span class="pw-reset">${icon('clock', 11)}${reset}</span>` : ''}</span>
  </div>`
}

function accountCard(a: QuotaAccount): string {
  if (!a.available) {
    // 有凭据但失败的账号显示一行原因（no_credentials/loading 的直接隐藏，不占版面）
    if (a.unavailableReason === 'no_credentials' || a.unavailableReason === 'loading') return ''
    return `<div class="card plan-card"><div class="card-label">${esc(a.label)}</div><div class="card-sub">未能读取（${esc(a.unavailableReason ?? 'unknown')}${a.error ? '：' + esc(a.error) : ''}）</div></div>`
  }
  const kind = KIND_SHORT[a.kind] ?? a.kind
  const logo = LOGOS[a.kind]
  const badge = a.planName && a.planName !== kind ? `<span class="plan-badge" title="${esc(a.planName)}">${esc(a.planName)}</span>` : ''
  const resetCount = typeof a.resetCredits === 'number' ? a.resetCredits : null
  const resetBadge = resetCount && resetCount > 0
    ? `<span class="plan-badge plan-reset" title="额度重置卡：共 ${resetCount} 张，当前额度状态下可用 ${typeof a.applicableResetCredits === 'number' ? a.applicableResetCredits : 0} 张">重置卡 ×${resetCount}</span>`
    : ''
  return `<div class="card plan-card">
    <div class="plan-head">
      ${logo
    ? `<img class="plan-logo" src="/logos/${logo}" alt="" width="28" height="28" />`
    : `<span class="plan-logo plan-logo-fallback">${esc(kind.slice(0, 1).toUpperCase())}</span>`}
      <span class="plan-name">${esc(kind)}</span>
      ${badge}${resetBadge}
      <span class="plan-fresh" title="数据时间 ${fmtTime(a.lastSuccessAt ?? a.fetchedAt)}"></span>
    </div>
    ${a.windows.length ? a.windows.map(windowRow).join('') : '<div class="card-sub">套餐生效中，暂无额度窗口数据</div>'}
  </div>`
}

export async function renderPlan(): Promise<void> {
  const el = document.getElementById('plan')!
  const seq = ++renderSeq
  const snap = await getJson<QuotaSnapshot>('/api/plan')
  if (seq !== renderSeq) return
  const cards = (snap.accounts ?? []).map(accountCard).filter(Boolean)
  el.innerHTML = cards.length
    ? `<h3 class="section-title">订阅额度</h3><div class="plan-grid">${cards.join('')}</div>`
    : ''
}
