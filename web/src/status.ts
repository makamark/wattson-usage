// web/src/status.ts — 底部状态区：数据新鲜度、采集错误、口径说明。
// 返回 status 载荷供 main.ts 更新顶栏「数据时间」，避免重复请求。
import { api } from './api.js'
import { esc } from './format.js'

export interface StatusPayload {
  fetchedAt: number
  // 最近一次成功采集时间；与 fetchedAt（尝试时间）拆分，失败轮不伪装成新数据
  lastSuccessAt?: number | null
  refreshing?: boolean
  errors?: unknown[]
  recordCount?: number
  localHost?: string
}

export async function renderStatus(): Promise<StatusPayload> {
  const el = document.getElementById('status')!
  const s: StatusPayload = await api.status()
  const errs = (s.errors ?? []) as unknown[]
  el.innerHTML = `<span>记录 ${s.recordCount ?? 0} 条</span>
    ${errs.length ? `<span class="err">采集异常：${errs.map(e => esc(String(e))).join('；')}</span>` : '<span class="ok">采集正常</span>'}
    <span>数据口径与配置来源见「设置」页</span>`
  return s
}
