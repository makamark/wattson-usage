import { join, resolve } from 'path'
import { homedir } from 'os'

import { calculateCost } from '../models.js'
import { isSqliteAvailable, getSqliteLoadError, openDatabase, type SqliteDatabase } from '../sqlite.js'
import { loadDeviceRoots } from './device-roots.js'
import type { Provider, SessionSource, SessionParser, ParsedProviderCall, ProbeRoot } from './types.js'

/// WorkBuddy (desktop app) tracks usage per session in a local SQLite db at
/// ~/.workbuddy/workbuddy.db: session_usage.used is the session's total token
/// count (basis unverifiable locally — treated as an ESTIMATE), joined with
/// sessions for cwd/model/updated_at. Session-level granularity: one call per
/// session, timestamped at updated_at.

type UsageRow = {
  session_id: string
  used: number
  updated_at: number
  model: string | null
  cwd: string | null
}

function sanitizeProject(path: string): string {
  return path.replace(/^\//, '').replace(/\//g, '-')
}

function epochMsToIso(ms: number | null): string {
  if (ms === null || !Number.isFinite(ms) || ms <= 0) return new Date(0).toISOString()
  return new Date(ms).toISOString()
}

function normalizeModel(model: string | null): string {
  return (model ?? 'unknown').replace(/^custom-local:/, '')
}

function validateSchema(db: SqliteDatabase): boolean {
  try {
    db.query<{ cnt: number }>('SELECT COUNT(*) as cnt FROM session_usage LIMIT 1')
    db.query<{ cnt: number }>('SELECT COUNT(*) as cnt FROM sessions LIMIT 1')
    return true
  } catch {
    return false
  }
}

function discover(dbPath: string): SessionSource[] {
  let db: SqliteDatabase
  try {
    db = openDatabase(dbPath)
  } catch {
    return []
  }
  try {
    if (!validateSchema(db)) return []
    const rows = db.query<UsageRow>(
      `SELECT su.session_id as session_id, su.used as used, su.updated_at as updated_at,
              s.model as model, s.cwd as cwd
       FROM session_usage su JOIN sessions s ON s.id = su.session_id
       WHERE su.used > 0 AND s.deleted_at IS NULL`,
    )
    return rows.map(row => ({
      path: `${dbPath}:${row.session_id}`,
      project: row.cwd ? sanitizeProject(row.cwd) : 'unknown',
      provider: 'workbuddy',
    }))
  } catch {
    return []
  } finally {
    db.close()
  }
}

function createParser(source: SessionSource, seenKeys: Set<string>): SessionParser {
  return {
    async *parse(): AsyncGenerator<ParsedProviderCall> {
      if (!isSqliteAvailable()) {
        process.stderr.write(getSqliteLoadError() + '\n')
        return
      }

      // Source paths are `<dbPath>:<sessionId>`. Split from the right so a colon
      // in the path (Windows drive letter) doesn't corrupt the session id.
      const segments = source.path.split(':')
      const sessionId = segments[segments.length - 1]!
      const dbPath = segments.slice(0, -1).join(':')

      let db: SqliteDatabase
      try {
        db = openDatabase(dbPath)
      } catch (err) {
        process.stderr.write(
          `codeburn: cannot open WorkBuddy database: ${err instanceof Error ? err.message : err}\n`,
        )
        return
      }

      try {
        if (!validateSchema(db)) return

        const rows = db.query<UsageRow>(
          `SELECT su.session_id as session_id, su.used as used, su.updated_at as updated_at,
                  s.model as model, s.cwd as cwd
           FROM session_usage su JOIN sessions s ON s.id = su.session_id
           WHERE su.session_id = ? AND su.used > 0 AND s.deleted_at IS NULL`,
          [sessionId],
        )

        for (const row of rows) {
          const dedupKey = `workbuddy:${row.session_id}`
          if (seenKeys.has(dedupKey)) continue
          seenKeys.add(dedupKey)

          const model = normalizeModel(row.model)
          const used = Math.max(0, row.used ?? 0)

          yield {
            provider: 'workbuddy',
            model,
            inputTokens: used,
            outputTokens: 0,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0,
            cachedInputTokens: 0,
            reasoningTokens: 0,
            webSearchRequests: 0,
            costUSD: calculateCost(model, used, 0, 0, 0, 0),
            costIsEstimated: true,
            tools: [],
            bashCommands: [],
            timestamp: epochMsToIso(row.updated_at),
            speed: 'standard',
            deduplicationKey: dedupKey,
            userMessage: '',
            sessionId: row.session_id,
            project: row.cwd ? sanitizeProject(row.cwd) : 'unknown',
            workingDirectory: row.cwd ?? undefined,
          }
        }
      } finally {
        db.close()
      }
    },
  }
}

export function createWorkbuddyProvider(dbPathOverride?: string): Provider {
  const dbPath = dbPathOverride ?? join(process.env['WORKBUDDY_HOME'] ?? join(homedir(), '.workbuddy'), 'workbuddy.db')
  return {
    name: 'workbuddy',
    displayName: 'WorkBuddy',

    modelDisplayName(model: string): string {
      return model
    },

    toolDisplayName(rawTool: string): string {
      return rawTool
    },

    async probeRoots(): Promise<ProbeRoot[]> {
      return [{ path: dbPath, label: 'db' }]
    },

    async discoverSessions(): Promise<SessionSource[]> {
      if (!isSqliteAvailable()) return []
      const sources = discover(dbPath)
      // devices.json (device-roots.ts) may mirror this db from other hosts;
      // walk those roots too, skipping the local db to avoid double-counting.
      const seen = new Set(sources.map(s => s.path))
      for (const device of loadDeviceRoots()) {
        if (!device.workbuddyDb || resolve(device.workbuddyDb) === resolve(dbPath)) continue
        for (const source of discover(device.workbuddyDb)) {
          if (!seen.has(source.path)) {
            seen.add(source.path)
            sources.push(source)
          }
        }
      }
      return sources
    },

    createSessionParser(source: SessionSource, seenKeys: Set<string>): SessionParser {
      return createParser(source, seenKeys)
    },
  }
}

export const workbuddy = createWorkbuddyProvider()
