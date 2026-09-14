// web/src/icons.ts — 内联 SVG 图标（16px 线性风，stroke=currentColor，零依赖）。
// 统一出口 icon(name)，未知名称返回空串兜底。
const PATHS: Record<string, string> = {
  home: '<path d="M3 9.5 8 5l5 4.5V13a.9.9 0 0 1-.9.9H9.8V10H6.2v3.9H3.9A.9.9 0 0 1 3 13Z"/>',
  chart: '<path d="M4 13.5V8.5M8 13.5v-9M12 13.5V6"/>',
  layers: '<path d="m8 2.5 5.5 3L8 8.5l-5.5-3Z"/><path d="m2.5 8.5 5.5 3 5.5-3"/><path d="m2.5 11.5 5.5 3 5.5-3"/>',
  monitor: '<rect x="2.5" y="3.5" width="11" height="8" rx="1"/><path d="M5.5 13.5h5M8 11.5v2"/>',
  settings: '<circle cx="8" cy="8" r="2"/><path d="M8 1.8v2M8 12.2v2M13.4 8h-2M2.6 8h2M11.8 4.2l-1.4 1.4M3.6 12.4 5 11M11.8 11.8l-1.4-1.4M3.6 3.6 5 5"/>',
  tokens: '<ellipse cx="8" cy="4.5" rx="5" ry="2"/><path d="M3 4.5v7c0 1.1 2.2 2 5 2s5-.9 5-2v-7M3 8c0 1.1 2.2 2 5 2s5-.9 5-2"/>',
  cost: '<circle cx="8" cy="8" r="5.8"/><path d="M10.2 6.2c-.4-.8-1.2-1.2-2.2-1.2-1.3 0-2.2.7-2.2 1.6 0 2.3 4.6 1 4.6 3.1 0 .9-1 1.6-2.4 1.6-1.1 0-2-.5-2.4-1.3M8 3.8v8.4"/>',
  calls: '<path d="M5 3.5h7.5v9H5a1.5 1.5 0 0 1-1.5-1.5V5A1.5 1.5 0 0 1 5 3.5Z"/><path d="M6 6h4.5M6 8.2h4.5M6 10.4h2.5"/>',
  zap: '<path d="M8.8 1.8 3.5 9h3.4l-.7 5.2L11.5 7H8.1Z"/>',
  calendar: '<rect x="2.5" y="3.5" width="11" height="10" rx="1"/><path d="M2.5 6.5h11M5.5 2v2.5M10.5 2v2.5"/>',
  refresh: '<path d="M13 8a5 5 0 1 1-1.5-3.6M13 2.5v2.6h-2.6"/>',
  clock: '<circle cx="8" cy="8" r="5.8"/><path d="M8 4.8V8l2.2 1.4"/>',
  bolt: '<path d="M8.8 1.2 3 9.4h3.8L6.4 14.8 13 6.4H9Z"/>',
  chevronDown: '<path d="m4 6.5 4 4 4-4"/>',
}

export function icon(name: string, size = 16): string {
  const body = PATHS[name]
  if (!body) return ''
  return `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 16 16" fill="none" ` +
    `stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`
}
