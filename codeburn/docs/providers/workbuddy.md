# WorkBuddy

WorkBuddy desktop coding app, which records per-session usage in a local SQLite database.

- **Source:** `src/providers/workbuddy.ts`
- **Loading:** lazy (`src/providers/index.ts`), like ZCode — it reads SQLite via `node:sqlite`.
- **Test:** `tests/providers/workbuddy.test.ts` (5 tests, fixture-based; schema verified against a live db on 2026-09-10)

## Where it reads from

`~/.workbuddy/workbuddy.db` (override with `WORKBUDDY_HOME`, which becomes `<dir>/workbuddy.db`). Mirrored dbs from other hosts listed under `workbuddyDb` in `devices.json` (`src/providers/device-roots.ts`) are discovered too.

## Storage format

SQLite tables `session_usage` (`session_id`, `used`, `size`, `updated_at` epoch ms, `credit_json`) and `sessions` (`id`, `cwd`, `model`, `deleted_at`, ...). Only sessions with `used > 0` and `deleted_at IS NULL` are discovered.

## Granularity and cost

One call per session: `used` (the session's total token count, basis unverifiable) is reported as `inputTokens` with every other bucket at 0 and `costIsEstimated: true`; `timestamp` is `session_usage.updated_at`. The `custom-local:` model prefix is stripped before pricing. Dedup key: `workbuddy:<session_id>`; source path: `<dbPath>:<session_id>`.
