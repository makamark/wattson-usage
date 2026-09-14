// server/tests/config.test.ts
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { loadFileConfig, ConfigError } from '../src/config.js'

let file: string
beforeEach(async () => { file = join(await mkdtemp(join(tmpdir(), 'cfg-')), 'agg.config.json') })
afterEach(async () => { await rm(join(file, '..'), { recursive: true, force: true }) })

describe('loadFileConfig', () => {
  it('reads server section from the config file', async () => {
    await writeFile(file, JSON.stringify({ server: { port: 9000, refreshMinutes: 15 }, devices: [] }))
    expect(await loadFileConfig(file)).toEqual({ port: 9000, refreshMinutes: 15 })
  })
  it('reads webDist through', async () => {
    await writeFile(file, JSON.stringify({ server: { port: 9000, webDist: '/x/web/dist' } }))
    expect(await loadFileConfig(file)).toEqual({ port: 9000, webDist: '/x/web/dist' })
  })
  it('returns {} when file missing', async () => {
    expect(await loadFileConfig(file)).toEqual({})
  })
  it('rejects corrupt JSON instead of silently defaulting (fail-fast)', async () => {
    await writeFile(file, '{bad')
    await expect(loadFileConfig(file)).rejects.toBeInstanceOf(ConfigError)
  })
  it('rejects non-object top level', async () => {
    await writeFile(file, '[1,2]')
    await expect(loadFileConfig(file)).rejects.toBeInstanceOf(ConfigError)
  })
  it('rejects out-of-range port / non-integer refreshMinutes', async () => {
    await writeFile(file, JSON.stringify({ server: { port: 70000 } }))
    await expect(loadFileConfig(file)).rejects.toBeInstanceOf(ConfigError)
    await writeFile(file, JSON.stringify({ server: { port: 9000, refreshMinutes: 1.5 } }))
    await expect(loadFileConfig(file)).rejects.toBeInstanceOf(ConfigError)
    await writeFile(file, JSON.stringify({ server: { port: '9000' } }))
    await expect(loadFileConfig(file)).rejects.toBeInstanceOf(ConfigError)
  })
})
