import { mkdtemp, rm } from 'fs/promises'
import { join } from 'path'
import { tmpdir } from 'os'
import { createRequire } from 'node:module'

import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { isSqliteAvailable } from '../../src/sqlite.js'
import { createWorkbuddyProvider } from '../../src/providers/workbuddy.js'

const requireForTest = createRequire(import.meta.url)

let tmpRoot: string

beforeEach(async () => {
  tmpRoot = await mkdtemp(join(tmpdir(), 'workbuddy-test-'))
})

afterEach(async () => {
  await rm(tmpRoot, { recursive: true, force: true })
})

// Minimal subset of the real WorkBuddy schema (verified against a live
// ~/.workbuddy/workbuddy.db on 2026-09-10) covering only the columns the
// provider reads.
function createWorkbuddyDb(dir: string): string {
  const dbPath = join(dir, 'workbuddy.db')
  const { DatabaseSync: Database } = requireForTest('node:sqlite')
  const db = new Database(dbPath)
  db.exec(`
    CREATE TABLE session_usage (
      session_id TEXT PRIMARY KEY,
      used INTEGER NOT NULL,
      size INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      credit_json TEXT
    )
  `)
  db.exec(`
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      cwd TEXT NOT NULL,
      title TEXT,
      status TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      deleted_at INTEGER,
      model TEXT
    )
  `)
  db.exec(`
    INSERT INTO sessions (id, cwd, title, status, created_at, updated_at, deleted_at, model)
    VALUES ('s1','/Users/tester/WorkBuddy/Claw','t','Done',1,1788862557465,NULL,'deepseek-v4-flash'),
           ('s2','/tmp/x','t2','Done',1,1788862557466,NULL,'custom-local:gpt-5.6-sol'),
           ('s3','/tmp/deleted','t3','Done',1,1788862557467,1,'m')
  `)
  db.exec(`
    INSERT INTO session_usage VALUES
      ('s1',321441,1000000,1788862557465,NULL),
      ('s2',106624,1000000,1788862557466,NULL),
      ('s3',999,1000000,1788862557467,NULL)
  `)
  db.close()
  return dbPath
}

;(isSqliteAvailable() ? describe : describe.skip)('workbuddy provider', () => {
  it('discovers sessions with usage from live db only', async () => {
    const dbPath = createWorkbuddyDb(tmpRoot)
    const provider = createWorkbuddyProvider(dbPath)
    const sources = await provider.discoverSessions()

    expect(sources.map(s => s.path)).toEqual([`${dbPath}:s1`, `${dbPath}:s2`])
    expect(sources[0]?.provider).toBe('workbuddy')
  })

  it('parses one call per session with used as estimated input', async () => {
    const dbPath = createWorkbuddyDb(tmpRoot)
    const provider = createWorkbuddyProvider(dbPath)
    const sources = await provider.discoverSessions()
    const calls = []
    for await (const call of provider.createSessionParser(sources[0]!, new Set<string>()).parse()) {
      calls.push(call)
    }

    expect(calls).toHaveLength(1)
    const c = calls[0]!
    expect(c.provider).toBe('workbuddy')
    expect(c.sessionId).toBe('s1')
    expect(c.model).toBe('deepseek-v4-flash')
    expect(c.inputTokens).toBe(321441)
    expect(c.costIsEstimated).toBe(true)
    expect(c.deduplicationKey).toBe('workbuddy:s1')
    expect(c.project).toBeTruthy()
    expect(c.workingDirectory).toBe('/Users/tester/WorkBuddy/Claw')
    expect(c.timestamp).toBe(new Date(1788862557465).toISOString())
  })

  it('strips custom-local: model prefix', async () => {
    const dbPath = createWorkbuddyDb(tmpRoot)
    const provider = createWorkbuddyProvider(dbPath)
    const sources = await provider.discoverSessions()
    for await (const c of provider.createSessionParser(sources[1]!, new Set<string>()).parse()) {
      expect(c.model).toBe('gpt-5.6-sol')
    }
  })

  it('dedup: second parse yields nothing', async () => {
    const dbPath = createWorkbuddyDb(tmpRoot)
    const provider = createWorkbuddyProvider(dbPath)
    const sources = await provider.discoverSessions()
    const seen = new Set<string>()

    for await (const _ of provider.createSessionParser(sources[0]!, seen).parse()) void _
    const calls2 = []
    for await (const c of provider.createSessionParser(sources[0]!, seen).parse()) calls2.push(c)

    expect(calls2).toHaveLength(0)
  })

  it('probeRoots reports db path', async () => {
    const dbPath = createWorkbuddyDb(tmpRoot)
    const provider = createWorkbuddyProvider(dbPath)
    expect((await provider.probeRoots!())[0]?.path).toBe(dbPath)
  })
})
