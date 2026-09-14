// web/src/api.ts — agg-server REST 客户端。所有路径走同源（dev 由 vite 代理）。
export async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(path)
  if (!res.ok) throw new Error(`${path}: ${res.status}`)
  return res.json() as Promise<T>
}

export const api = {
  overview: (q: Record<string, string> = {}) => getJson<any>('/api/overview?' + new URLSearchParams(q)),
  series: (q: Record<string, string>) => getJson<any>('/api/series?' + new URLSearchParams(q)),
  matrix: (q: Record<string, string>) => getJson<any>('/api/matrix?' + new URLSearchParams(q)),
  models: (q: Record<string, string> = {}) => getJson<any[]>('/api/models?' + new URLSearchParams(q)),
  status: <T = any>() => getJson<T>('/api/status'),
  refresh: () => fetch('/api/refresh', { method: 'POST' }),
}
