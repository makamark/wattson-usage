// app/src/config.ts — 客户端路径与配置读写。
// 配置文件位置：打包态放 ~/codeburn-agg/agg.config.json（用户数据域，与镜像/日志同处）；
// 开发态沿用仓库根 agg.config.json，与本机已装的 launchd 服务共用同一份配置、互不打架。
import { app } from 'electron'
import { existsSync, mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import { homedir, hostname } from 'node:os'
import { dirname, join } from 'node:path'

export type Device = { name: string; local?: boolean; ssh?: string }
export type Config = { server?: { port?: number; refreshMinutes?: number; webDist?: string }; devices?: Device[] }

// 设备名校验：设备名会用作本地镜像目录名、远端 /tmp 临时文件后缀并进入看板「设备」
// 维度；SSH 目标是 ssh 的命令行参数。二者都必须是受限字符集（与 sync/mirror.sh 的
// valid_name/valid_ssh 同口径），防止 shell 元字符、路径穿越与选项注入。
export const DEVICE_NAME_RE = /^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$/
export function validSshTarget(s: string): boolean {
  return !s.startsWith('-') && /^[A-Za-z0-9._@%:+-]{1,255}$/.test(s)
}

/** 仓库根：开发态=app/ 上级；打包态=.app 内 Resources/wattson（server/codeburn/web/sync 均在此）。
 *  开发态做 realpath：与 server 侧 fileURLToPath 的模块真实路径口径一致（仓库目录可能是符号链接），
 *  /api/status 的 configPath 握手比较才不会因符号链接误报「不同配置」。 */
export const REPO_ROOT = app.isPackaged
  ? join(process.resourcesPath, 'wattson')
  : join(realpathSync(app.getAppPath()), '..')

export const CONFIG_PATH = app.isPackaged
  ? join(homedir(), 'codeburn-agg', 'agg.config.json')
  : join(REPO_ROOT, 'agg.config.json')

export const MIRROR_SCRIPT = join(REPO_ROOT, 'sync', 'mirror.sh')
export const DEVICES_FILE = process.env['CODEBURN_DEVICES_FILE']
  ?? join(homedir(), '.config', 'codeburn', 'devices.json')

/** 本机设备名，与 server collector 的 localHost 口径一致（hostname 短名） */
export const localName = (): string => hostname().replace(/\..*$/, '')

export const hasConfig = (): boolean => existsSync(CONFIG_PATH)

export function readConfig(): Config | null {
  try { return JSON.parse(readFileSync(CONFIG_PATH, 'utf8')) as Config } catch { return null }
}

/** 原子写（临时文件 + rename）：半写的配置不会落盘成「合法但缺字段的旧值」 */
export function writeConfig(cfg: Config): void {
  mkdirSync(dirname(CONFIG_PATH), { recursive: true })
  const tmp = CONFIG_PATH + '.tmp'
  writeFileSync(tmp, JSON.stringify(cfg, null, 2) + '\n')
  renameSync(tmp, CONFIG_PATH)
}

/** scripts/gen-config.py 的 TS 移植：远端设备 → ~/.config/codeburn/devices.json（镜像根） */
export function genDevicesJson(cfg: Config): number {
  const devices = (cfg.devices ?? [])
    .filter(d => !d.local && typeof d.ssh === 'string' && d.ssh)
    .map(d => ({
      host: d.name,
      zcodeDb: `~/codeburn-agg/mirror/${d.name}/zcode/db.sqlite`,
      codexHome: `~/codeburn-agg/mirror/${d.name}/codex`,
      workbuddyDb: `~/codeburn-agg/mirror/${d.name}/workbuddy/db.sqlite`,
    }))
  mkdirSync(dirname(DEVICES_FILE), { recursive: true })
  const tmp = DEVICES_FILE + '.tmp'
  writeFileSync(tmp, JSON.stringify(devices, null, 2) + '\n')
  renameSync(tmp, DEVICES_FILE)
  return devices.length
}

/** 客户端要连的端口（env CODEBURN_AGG_PORT > 配置文件 > 8317，与服务端优先级一致） */
export function configuredPort(cfg: Config | null): number {
  const env = Number(process.env['CODEBURN_AGG_PORT'])
  if (Number.isFinite(env) && env > 0) return env
  const p = cfg?.server?.port
  return typeof p === 'number' && Number.isFinite(p) && p > 0 ? p : 8317
}

/** 本机数据源探测，路径口径与 scripts/setup.sh 一致 */
export function probeLocalTools(): string[] {
  const home = homedir()
  const out: string[] = []
  if (existsSync(join(home, '.zcode/cli/db/db.sqlite'))) out.push('zcode')
  if (existsSync(join(home, '.codex/sessions'))) out.push('codex')
  if (existsSync(join(home, '.workbuddy/workbuddy.db'))) out.push('workbuddy')
  return out
}
