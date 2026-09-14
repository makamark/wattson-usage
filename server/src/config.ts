// server/src/config.ts — agg.config.json server 节解析；env 覆盖在 main.ts。
// 配置文件路径可由 AGG_CONFIG 指定（菜单栏客户端打包态指向 ~/codeburn-agg/agg.config.json），
// 默认仓库根（server/src 的上上级）。
// 语义：文件不存在 = 全默认（首次运行）；文件存在但损坏/字段非法 = 抛 ConfigError
// 让入口 fail-fast——坏配置静默当默认会掩盖端口/刷新间隔错乱。
import { readFile } from 'node:fs/promises'

export class ConfigError extends Error {}

export type FileConfig = { port?: number; refreshMinutes?: number; webDist?: string }

export async function loadFileConfig(file: string): Promise<FileConfig> {
  let raw: string
  try {
    raw = await readFile(file, 'utf8')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return {}
    throw err
  }
  let parsed: unknown
  try { parsed = JSON.parse(raw) } catch {
    throw new ConfigError(`配置文件不是合法 JSON：${file}`)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new ConfigError(`配置文件顶层必须是对象：${file}`)
  }
  const s = (parsed as { server?: unknown }).server ?? {}
  if (typeof s !== 'object' || s === null || Array.isArray(s)) {
    throw new ConfigError(`配置 server 节必须是对象：${file}`)
  }
  const o = s as Record<string, unknown>
  const intField = (key: string, min: number, max: number): number | undefined => {
    const v = o[key]
    if (v === undefined) return undefined
    if (typeof v !== 'number' || !Number.isInteger(v) || v < min || v > max) {
      throw new ConfigError(`配置 server.${key} 必须是 ${min}–${max} 的整数，实际：${String(v)}`)
    }
    return v
  }
  const out: FileConfig = {}
  const port = intField('port', 1, 65535)
  if (port !== undefined) out.port = port
  const refreshMinutes = intField('refreshMinutes', 1, 24 * 60)
  if (refreshMinutes !== undefined) out.refreshMinutes = refreshMinutes
  if (o['webDist'] !== undefined) {
    if (typeof o['webDist'] !== 'string' || !o['webDist']) {
      throw new ConfigError(`配置 server.webDist 必须是非空字符串，实际：${String(o['webDist'])}`)
    }
    out.webDist = o['webDist']
  }
  return out
}
