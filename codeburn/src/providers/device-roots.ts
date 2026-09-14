import { readFileSync, statSync } from 'fs'
import { homedir } from 'os'
import { join, resolve, sep } from 'path'

/// devices.json multi-device roots.
///
/// The aggregator mirrors per-device provider stores under one tree (e.g.
/// ~/codeburn-agg/mirror/<host>/zcode/db.sqlite). devices.json declares which
/// on-disk roots belong to which remote host so session sources can be
/// attributed to a device instead of always reporting the local one:
///
///   [{ "host": "macpro", "zcodeDb": "~/codeburn-agg/mirror/macpro/zcode/db.sqlite",
///      "codexHome": "~/codeburn-agg/mirror/macpro/codex", "workbuddyDb": "..." }]
///
/// zcode/workbuddy sources are cached as `<dbPath>:<sessionId>` (colon
/// suffix), codex sources are file paths under its home directory, so both
/// shapes must prefix-match. Missing/invalid config is not an error: every
/// source simply attributes to the local host.

export type DeviceRoot = {
  host: string
  zcodeDb?: string
  codexHome?: string
  workbuddyDb?: string
}

export function expandHome(p: string): string {
  if (p === '~') return homedir()
  if (p.startsWith('~/')) return join(homedir(), p.slice(2))
  return p
}

function devicesFile(): string {
  return process.env['CODEBURN_DEVICES_FILE'] ?? join(homedir(), '.config', 'codeburn', 'devices.json')
}

// Config rarely changes within a process; re-read only when the file's
// mtime moves. Keyed on (file, mtimeMs) so pointing CODEBURN_DEVICES_FILE at
// a different file always re-reads.
let memo: { file: string; mtimeMs: number; roots: DeviceRoot[] } | null = null

export function loadDeviceRoots(): DeviceRoot[] {
  const file = devicesFile()
  let mtimeMs = 0
  try {
    mtimeMs = statSync(file).mtimeMs
  } catch {
    return []
  }
  if (memo && memo.file === file && memo.mtimeMs === mtimeMs) return memo.roots
  let roots: DeviceRoot[] = []
  try {
    const parsed: unknown = JSON.parse(readFileSync(file, 'utf8'))
    if (Array.isArray(parsed)) {
      roots = parsed
        .filter((d): d is DeviceRoot => !!d && typeof d === 'object' && typeof (d as DeviceRoot).host === 'string')
        .map(d => ({
          host: d.host,
          zcodeDb: d.zcodeDb ? resolve(expandHome(d.zcodeDb)) : undefined,
          codexHome: d.codexHome ? resolve(expandHome(d.codexHome)) : undefined,
          workbuddyDb: d.workbuddyDb ? resolve(expandHome(d.workbuddyDb)) : undefined,
        }))
    }
  } catch {
    roots = []
  }
  memo = { file, mtimeMs, roots }
  return roots
}

export function hostForSourcePath(path: string, localHost: string): string {
  for (const d of loadDeviceRoots()) {
    for (const root of [d.zcodeDb, d.codexHome, d.workbuddyDb]) {
      if (root && (path === root || path.startsWith(root + sep) || path.startsWith(root + ':'))) return d.host
    }
  }
  return localHost
}
