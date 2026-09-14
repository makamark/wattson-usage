import { mkdtemp, rm, writeFile } from 'fs/promises'
import { join } from 'path'
import { tmpdir } from 'os'

import { describe, it, expect, beforeEach, afterEach } from 'vitest'

// Each test mints its own tmpdir and points CODEBURN_DEVICES_FILE at a
// per-test fixture file, so (a) the suite's env scrubbing can't leak a dev's
// real devices.json in (HOME is sandboxed too), and (b) the module's
// (file, mtimeMs) memo never serves a stale entry across tests — every test
// uses a distinct file path.

let tmpRoot: string
const origEnv = process.env['CODEBURN_DEVICES_FILE']

beforeEach(async () => {
  tmpRoot = await mkdtemp(join(tmpdir(), 'devroot-'))
})

afterEach(async () => {
  await rm(tmpRoot, { recursive: true, force: true })
  if (origEnv === undefined) delete process.env['CODEBURN_DEVICES_FILE']
  else process.env['CODEBURN_DEVICES_FILE'] = origEnv
})

describe('loadDeviceRoots', () => {
  it('returns [] when file missing', async () => {
    process.env['CODEBURN_DEVICES_FILE'] = join(tmpRoot, 'absent.json')
    const { loadDeviceRoots } = await import('../../src/providers/device-roots.js')
    expect(loadDeviceRoots()).toEqual([])
  })

  it('parses devices and expands ~', async () => {
    const file = join(tmpRoot, 'devices.json')
    await writeFile(file, JSON.stringify([{ host: 'macpro', zcodeDb: '~/codeburn-agg/mirror/macpro/zcode/db.sqlite' }]))
    process.env['CODEBURN_DEVICES_FILE'] = file
    const { loadDeviceRoots, expandHome } = await import('../../src/providers/device-roots.js')
    const roots = loadDeviceRoots()
    expect(roots).toEqual([{ host: 'macpro', zcodeDb: expandHome('~/codeburn-agg/mirror/macpro/zcode/db.sqlite') }])
  })

  it('returns [] on invalid JSON', async () => {
    const file = join(tmpRoot, 'bad.json')
    await writeFile(file, '{oops')
    process.env['CODEBURN_DEVICES_FILE'] = file
    const { loadDeviceRoots } = await import('../../src/providers/device-roots.js')
    expect(loadDeviceRoots()).toEqual([])
  })
})

describe('hostForSourcePath', () => {
  it('prefix-matches device db path (incl. ":sessionId" suffix)', async () => {
    const file = join(tmpRoot, 'devices.json')
    await writeFile(file, JSON.stringify([{ host: 'macpro', zcodeDb: '~/mirror/zcode/db.sqlite' }]))
    process.env['CODEBURN_DEVICES_FILE'] = file
    const { expandHome, hostForSourcePath } = await import('../../src/providers/device-roots.js')
    const db = expandHome('~/mirror/zcode/db.sqlite')
    expect(hostForSourcePath(`${db}:abc`, 'macair')).toBe('macpro')
    expect(hostForSourcePath('/Users/tester/.zcode/cli/db/db.sqlite:x', 'macair')).toBe('macair')
  })

  it('prefix-matches codexHome as a directory (sep boundary)', async () => {
    const file = join(tmpRoot, 'devices.json')
    await writeFile(file, JSON.stringify([{ host: 'macpro', codexHome: '~/.codex' }]))
    process.env['CODEBURN_DEVICES_FILE'] = file
    const { expandHome, hostForSourcePath } = await import('../../src/providers/device-roots.js')
    const root = expandHome('~/.codex')
    expect(hostForSourcePath(join(root, 'sessions', 'rollout-2026.jsonl'), 'macair')).toBe('macpro')
    // Sibling directory sharing the root as a string prefix must NOT match.
    expect(hostForSourcePath(root + 'box-sessions/x.jsonl', 'macair')).toBe('macair')
  })
})
