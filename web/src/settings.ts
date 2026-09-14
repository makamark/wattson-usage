// web/src/settings.ts — 设置页（只读）：服务状态与配置来源摘要 + 数据口径说明。
// 改配置不在这页做：走 Wattson.app 的初始化向导（多机 SSH 探测 + 校验 + 落盘），
// 或直接编辑 agg.config.json 后重启聚合服务；本页只负责「看清现状」。
import { api } from './api.js'
import { fmtInt, fmtTime, esc } from './format.js'

interface StatusInfo {
  localHost?: string
  fetchedAt?: number
  lastSuccessAt?: number | null
  refreshing?: boolean
  errors?: unknown[]
  recordCount?: number
  configPath?: string
  instanceId?: string
  port?: number
}

let renderSeq = 0

const row = (k: string, v: string): string =>
  `<div class="set-row"><span class="set-k">${esc(k)}</span><span class="set-v">${v}</span></div>`

export async function renderSettings(): Promise<void> {
  const el = document.getElementById('settings')!
  const seq = ++renderSeq
  const s = await api.status<StatusInfo>()
  if (seq !== renderSeq) return
  const errs = (s.errors ?? []) as unknown[]
  el.innerHTML = `
    <div class="settings-grid">
      <div class="card set-card">
        <h3>服务状态</h3>
        ${row('本机设备', esc(s.localHost ?? '—'))}
        ${row('监听端口', s.port ? String(s.port) : '—')}
        ${row('数据记录', s.recordCount !== undefined ? fmtInt(s.recordCount) + ' 条' : '—')}
        ${row('数据时间', fmtTime(s.lastSuccessAt ?? s.fetchedAt ?? Date.now()))}
        ${row('采集状态', s.refreshing ? '解析中…' : errs.length ? `<span class="err">异常 ×${errs.length}（见底部状态栏）</span>` : '<span class="ok">正常</span>')}
      </div>
      <div class="card set-card">
        <h3>配置来源</h3>
        ${row('配置文件', s.configPath ? `<code>${esc(s.configPath)}</code>` : '<span class="muted">经 Wattson.app 托管时提供</span>')}
        ${row('实例 ID', s.instanceId ? `<code>${esc(s.instanceId)}</code>` : '—')}
        <div class="set-note">
          修改设备/端口/刷新周期：打开 Wattson.app 菜单栏小窗 → 设置（向导会探测远端 SSH、
          写入配置并派生镜像 devices.json）；也可直接编辑配置文件后重启聚合服务。
        </div>
      </div>
      <div class="card set-card">
        <h3>数据口径</h3>
        <div class="set-note">
          · Token 总量口径与成本计费一致：reasoning-in-output 提供商的推理 token 不重复计入<br>
          · 成本按 LiteLLM 官方价估算（未映射模型按 $0 计，可用 codeburn model-alias 修正）<br>
          · workbuddy 为会话级估算<br>
          · 各区块共享同一份筛选（范围 + 维度钻取），口径一致
        </div>
      </div>
    </div>`
}
