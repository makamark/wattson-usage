// server/src/quotas/proxy.ts — 额度接口出网客户端：chatgpt.com / api.anthropic.com /
// cursor.com 在受限网络不可达，需要代理。Node 内置 fetch 的代理开关
//（NODE_USE_ENV_PROXY）只在进程启动前生效，launchd 下无法保证——因此用
// undici 的 ProxyAgent 显式构造 dispatcher（纯 JS 依赖，无版本门槛）。
// 代理地址：显式 HTTP(S)_PROXY env 优先；否则 macOS 用 `scutil --proxy` 探测系统代理。
import { execFileSync } from 'node:child_process'
import type { ProxyAgent, fetch as undiciFetchType } from 'undici'
import type { FetchLike } from './types.js'

export function nodeMajorVersion(version = process.versions.node): number {
  return Number.parseInt(version.split('.')[0] ?? '0', 10) || 0
}

export type SystemProxy = { httpsProxy: string | null; httpProxy: string | null }

/** 解析 `scutil --proxy` 输出（macOS）；非 mac / 解析失败返回空 */
export function parseScutilProxy(output: string): SystemProxy {
  const get = (key: string): string | null => {
    const m = new RegExp(`^\\s*${key}\\s*:\\s*(\\S+)`, 'm').exec(output)
    return m?.[1] ?? null
  }
  const enabled = (key: string): boolean => get(key) === '1'
  const host = (key: string): string | null => {
    const v = get(key)
    return v && v !== '0.0.0.0' ? v : null
  }
  const port = (key: string): string | null => {
    const v = get(key)
    return v && v !== '0' ? v : null
  }
  const build = (enableKey: string, hostKey: string, portKey: string): string | null => {
    if (!enabled(enableKey)) return null
    const h = host(hostKey)
    const p = port(portKey)
    return h && p ? `http://${h}:${p}` : h ? `http://${h}` : null
  }
  return {
    httpsProxy: build('HTTPSEnable', 'HTTPSProxy', 'HTTPSPort'),
    httpProxy: build('HTTPEnable', 'HTTPProxy', 'HTTPPort'),
  }
}

/** 代理地址解析：显式 env 优先，其次 macOS 系统代理；都没有返回 null（直连） */
export function resolveProxyUrl(opts: {
  env?: NodeJS.ProcessEnv
  platform?: string
  scutil?: () => string
} = {}): string | null {
  const env = opts.env ?? process.env
  const platform = opts.platform ?? process.platform
  const explicit = env['HTTPS_PROXY'] ?? env['https_proxy'] ?? env['HTTP_PROXY'] ?? env['http_proxy']
  if (explicit && explicit.trim()) return explicit.trim()
  if (platform !== 'darwin') return null
  try {
    const out = opts.scutil ? opts.scutil() : execFileSync('/usr/sbin/scutil', ['--proxy'], { encoding: 'utf8' })
    const sys = parseScutilProxy(out)
    return sys.httpsProxy ?? sys.httpProxy
  } catch {
    return null
  }
}

/**
 * 构造额度接口专用 fetch：配置了代理时走 undici ProxyAgent（运行时生效），
 * 否则退回全局 fetch 直连。undici 按需懒加载（未配代理时不引入）。
 */
export async function createQuotaFetch(opts: {
  env?: NodeJS.ProcessEnv
  platform?: string
  scutil?: () => string
} = {}): Promise<{ fetchLike: FetchLike; proxyUrl: string | null }> {
  const proxyUrl = resolveProxyUrl(opts)
  if (!proxyUrl) return { fetchLike: (url, init) => fetch(url, init), proxyUrl: null }
  const mod = (await import('undici')) as { ProxyAgent: typeof ProxyAgent; fetch: typeof undiciFetchType }
  const agent = new mod.ProxyAgent(proxyUrl)
  const fetchLike: FetchLike = async (url, init) => {
    const res = await mod.fetch(url, {
      method: init.method as 'GET' | 'POST' | undefined,
      headers: init.headers,
      body: init.body as string | undefined,
      signal: init.signal,
      dispatcher: agent,
    } as Parameters<typeof mod.fetch>[1])
    return { ok: res.ok, status: res.status, json: () => res.json() }
  }
  return { fetchLike, proxyUrl }
}
