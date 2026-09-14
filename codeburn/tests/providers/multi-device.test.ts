import { mkdirSync } from 'fs'
import { mkdtemp, mkdir, rm, writeFile } from 'fs/promises'
import { join } from 'path'
import { tmpdir } from 'os'
import { createRequire } from 'node:module'

import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { isSqliteAvailable } from '../../src/sqlite.js'
import { createZcodeProvider } from '../../src/providers/zcode.js'
import { createCodexProvider } from '../../src/providers/codex.js'

const requireForTest = createRequire(import.meta.url)

let tmpRoot: string
const origEnv = process.env['CODEBURN_DEVICES_FILE']

beforeEach(async () => {
  tmpRoot = await mkdtemp(join(tmpdir(), 'multi-dev-'))
})

afterEach(async () => {
  await rm(tmpRoot, { recursive: true, force: true })
  // Each test points CODEBURN_DEVICES_FILE at a per-test fixture file, so the
  // device-roots (file, mtimeMs) memo never serves a stale entry across tests.
  if (origEnv === undefined) delete process.env['CODEBURN_DEVICES_FILE']
  else process.env['CODEBURN_DEVICES_FILE'] = origEnv
})

// Minimal subset of the real ZCode schema (db v0.14.8) covering only the
// columns the provider reads.
function createZcodeDb(dir: string): string {
  mkdirSync(dir, { recursive: true })
  const dbPath = join(dir, 'db.sqlite')
  const { DatabaseSync: Database } = requireForTest('node:sqlite')
  const db = new Database(dbPath)
  db.exec(`
    CREATE TABLE session (
      id TEXT PRIMARY KEY,
      directory TEXT NOT NULL
    )
  `)
  db.exec(`
    CREATE TABLE model_usage (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      turn_id TEXT,
      model_id TEXT NOT NULL,
      input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      reasoning_tokens INTEGER NOT NULL DEFAULT 0,
      cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
      started_at INTEGER NOT NULL,
      completed_at INTEGER
    )
  `)
  db.close()
  return dbPath
}

// Seeds one usage row per session so discover() lists it.
function seedZcode(dbPath: string, sessions: Array<{ id: string; directory: string }>): void {
  const { DatabaseSync: Database } = requireForTest('node:sqlite')
  const db = new Database(dbPath)
  try {
    for (const [i, s] of sessions.entries()) {
      db.prepare('INSERT INTO session (id, directory) VALUES (?, ?)').run(s.id, s.directory)
      db.prepare(
        `INSERT INTO model_usage
         (id, session_id, turn_id, model_id, input_tokens, output_tokens, reasoning_tokens,
          cache_creation_input_tokens, cache_read_input_tokens, started_at, completed_at)
         VALUES (?, ?, NULL, 'm1', ?, 0, 0, 0, 0, ?, NULL)`,
      ).run(`u-${i}`, s.id, 100, 1750000000000 + i)
    }
  } finally {
    db.close()
  }
}

async function writeDevicesFile(devices: unknown): Promise<string> {
  const file = join(tmpRoot, 'devices.json')
  await writeFile(file, JSON.stringify(devices))
  process.env['CODEBURN_DEVICES_FILE'] = file
  return file
}

;(isSqliteAvailable() ? describe : describe.skip)('zcode multi-device roots', () => {
  it('discovers local + device dbs', async () => {
    // Different rows per db (unlike identical mirror copies) so each expected
    // source pins exactly one db: the local db must contribute s-local and the
    // declared device db must contribute s-remote2.
    const localDb = createZcodeDb(join(tmpRoot, 'local'))
    seedZcode(localDb, [{ id: 's-local', directory: '/tmp/projA' }])
    const remoteDb = createZcodeDb(join(tmpRoot, 'remote'))
    seedZcode(remoteDb, [{ id: 's-remote2', directory: '/tmp/projB' }])
    await writeDevicesFile([{ host: 'macpro', zcodeDb: remoteDb }])

    const provider = createZcodeProvider(localDb)
    const sources = await provider.discoverSessions()
    const paths = sources.map(s => s.path)

    expect(paths).toContain(`${localDb}:s-local`)
    expect(paths).toContain(`${remoteDb}:s-remote2`)
    // No cross-db leakage: neither db invents the other's sessions.
    expect(paths).not.toContain(`${localDb}:s-remote2`)
    expect(paths).not.toContain(`${remoteDb}:s-local`)
  })

  it('skips device root equal to local db', async () => {
    const localDb = createZcodeDb(tmpRoot)
    seedZcode(localDb, [
      { id: 's-a', directory: '/tmp/projA' },
      { id: 's-b', directory: '/tmp/projB' },
    ])
    await writeDevicesFile([{ host: 'self', zcodeDb: localDb }])

    const provider = createZcodeProvider(localDb)
    const sources = await provider.discoverSessions()

    // Declaring the local db as a device root must not duplicate its sources.
    expect(sources.filter(s => s.path.startsWith(localDb)).length).toBe(2)
  })
})

describe('codex multi-device roots', () => {
  function sessionMeta(sessionId: string, cwd: string): string {
    return JSON.stringify({
      type: 'session_meta',
      timestamp: '2026-04-14T10:00:00Z',
      payload: {
        cwd,
        originator: 'codex-cli',
        session_id: sessionId,
        model: 'gpt-5.5',
      },
    })
  }

  function tokenCount(): string {
    return JSON.stringify({
      type: 'event_msg',
      timestamp: '2026-04-14T10:01:00Z',
      payload: {
        type: 'token_count',
        info: {
          last_token_usage: {
            input_tokens: 100,
            cached_input_tokens: 0,
            output_tokens: 50,
            reasoning_output_tokens: 0,
            total_tokens: 150,
          },
        },
      },
    })
  }

  async function writeRollout(home: string, filename: string, sessionId: string, cwd: string): Promise<string> {
    const sessionDir = join(home, 'sessions', '2026', '04', '14')
    await mkdir(sessionDir, { recursive: true })
    const filePath = join(sessionDir, filename)
    await writeFile(filePath, [sessionMeta(sessionId, cwd), tokenCount()].join('\n') + '\n')
    return filePath
  }

  it('discovers local home + device homes', async () => {
    const localHome = join(tmpRoot, 'local')
    const remoteHome = join(tmpRoot, 'macpro')
    const localPath = await writeRollout(localHome, 'rollout-local.jsonl', 'sess-local', '/Users/me/localproj')
    const remotePath = await writeRollout(remoteHome, 'rollout-remote.jsonl', 'sess-remote', '/Users/me/macproj')
    await writeDevicesFile([{ host: 'macpro', codexHome: remoteHome }])

    const provider = createCodexProvider(localHome)
    const sources = await provider.discoverSessions()
    const paths = sources.map(s => s.path)

    expect(paths).toContain(localPath)
    expect(paths).toContain(remotePath)
  })

  it('skips device home equal to the local home', async () => {
    const localHome = join(tmpRoot, 'local')
    const localPath = await writeRollout(localHome, 'rollout-local.jsonl', 'sess-local', '/Users/me/localproj')
    await writeDevicesFile([{ host: 'self', codexHome: localHome }])

    const provider = createCodexProvider(localHome)
    const sources = await provider.discoverSessions()

    // Declaring the local home as a device root must not duplicate its sources.
    expect(sources.map(s => s.path)).toEqual([localPath])
  })
})
