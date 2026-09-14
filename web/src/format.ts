// web/src/format.ts — 展示格式化工具。

/** 千分位整数 */
export const fmtInt = (n: number): string => n.toLocaleString('zh-CN', { maximumFractionDigits: 0 })

/** token 数量紧凑格式：1.23B / 4.56M / 78.9K */
export const fmtTokens = (n: number): string =>
  n >= 1e9 ? (n / 1e9).toFixed(2) + 'B'
    : n >= 1e6 ? (n / 1e6).toFixed(2) + 'M'
    : n >= 1e3 ? (n / 1e3).toFixed(1) + 'K'
    : String(n)

/** 金额：未映射（null）显示 —；小额保留 3 位精度 */
export const fmtCost = (n: number | null): string => n === null ? '—' : '$' + n.toFixed(n < 10 ? 3 : 2)

/** 本地时间戳 → 可读时间 */
export const fmtTime = (ms: number): string => new Date(ms).toLocaleString('zh-CN', { hour12: false })

/** HTML 转义（host/tool/model/project 等来源值经 innerHTML 渲染前使用） */
const ESC: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }
export const esc = (s: unknown): string => String(s).replace(/[&<>"']/g, c => ESC[c]!)
