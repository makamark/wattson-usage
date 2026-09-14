// server/src/quotas/poller.ts — 多 provider 订阅额度轮询：
// 单飞 + TTL（5 分钟）；各 provider 相互隔离，任一失败不影响其它；
// 全部失败/无凭据只体现在各自 account 的 unavailableReason 里。
import { homedir } from 'node:os'
import {
  fetchPlanSnapshot, readCodingPlanAuth, PLAN_TTL_MS, type PlanSnapshot,
} from '../plan.js'
import { codexAccount } from './codex.js'
import { claudeAccount } from './claude.js'
import { cursorAccount } from './cursor.js'
import { workbuddyAccount } from './workbuddy.js'
import { traeAccount } from './trae.js'
import { kimiAccount } from './kimi.js'
import { geminiAccount } from './gemini.js'
import { grokAccount } from './grok.js'
import { zedAccount } from './zed.js'
import { kiroAccount } from './kiro.js'
import { codebuffAccount } from './codebuff.js'
import { factoryAccount } from './factory.js'
import { copilotAccount } from './copilot.js'
import { openrouterAccount } from './openrouter.js'
import { minimaxAccount } from './minimax.js'
import type { FetchLike, QuotaAccount, QuotaSnapshot } from './types.js'

/** GLM 的 PlanSnapshot（绝对值口径）→ 统一 QuotaAccount */
export function glmToAccount(s: PlanSnapshot): QuotaAccount {
  return {
    kind: 'glm',
    label: 'GLM Coding Plan',
    available: s.available,
    unavailableReason: s.unavailableReason,
    error: s.error,
    planName: s.planName,
    windows: s.windows.map(w => ({
      key: w.key,
      label: w.label,
      total: w.total,
      used: w.used,
      remaining: w.remaining,
      percentage: w.percentage,
      nextResetAt: w.nextResetAt,
    })),
    fetchedAt: s.fetchedAt,
    lastSuccessAt: s.lastSuccessAt,
  }
}

const LOADING_GLM: QuotaAccount = {
  kind: 'glm', label: 'GLM Coding Plan', available: false,
  unavailableReason: 'loading', error: null, planName: null,
  windows: [], fetchedAt: 0, lastSuccessAt: null,
}

const LOADING_ACCOUNTS: QuotaAccount[] = [
  LOADING_GLM,
  { kind: 'codex', label: 'Codex (ChatGPT)', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'claude', label: 'Claude Code', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'cursor', label: 'Cursor', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'workbuddy', label: 'WorkBuddy', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'trae', label: 'Trae', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'kimi', label: 'Kimi', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'gemini', label: 'Gemini', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'grok', label: 'Grok', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'zed', label: 'Zed', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'kiro', label: 'Kiro', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'codebuff', label: 'Codebuff', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'factory', label: 'Factory', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'copilot', label: 'Copilot', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'openrouter', label: 'OpenRouter', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
  { kind: 'minimax', label: 'MiniMax', available: false, unavailableReason: 'loading', error: null, planName: null, windows: [], fetchedAt: 0, lastSuccessAt: null },
]

export class QuotaPoller {
  snapshot: QuotaSnapshot = { accounts: LOADING_ACCOUNTS }
  private inflight: Promise<void> | null = null
  private lastFetchAt = Number.NEGATIVE_INFINITY
  private readonly home: string
  private readonly env: NodeJS.ProcessEnv
  private readonly doFetch: FetchLike
  private readonly now: () => number

  constructor(opts: { home?: string; env?: NodeJS.ProcessEnv; fetchImpl?: FetchLike; now?: () => number } = {}) {
    this.home = opts.home ?? homedir()
    this.env = opts.env ?? process.env
    this.doFetch = opts.fetchImpl ?? (defaultFetch as unknown as FetchLike)
    this.now = opts.now ?? (() => Date.now())
  }

  /** 拉一轮全部 provider（带 TTL）；绝不 reject */
  async current(): Promise<QuotaSnapshot> {
    if (this.inflight) return this.inflight.then(() => this.snapshot)
    if (this.now() - this.lastFetchAt < PLAN_TTL_MS) return this.snapshot
    this.inflight = (async () => {
      const now = this.now()
      const results = await Promise.all([
        this.fetchGlm(now),
        Promise.resolve(codexAccount(this.home, this.env, this.doFetch, now)).catch(isolate('codex', now)),
        Promise.resolve(claudeAccount(this.home, this.env, this.doFetch, now)).catch(isolate('claude', now)),
        Promise.resolve(cursorAccount(this.home, this.env, this.doFetch, now)).catch(isolate('cursor', now)),
        Promise.resolve(workbuddyAccount(this.home, this.env, this.doFetch, now)).catch(isolate('workbuddy', now)),
        Promise.resolve(traeAccount(this.home, this.env, this.doFetch, now)).catch(isolate('trae', now)),
        Promise.resolve(kimiAccount(this.home, this.env, this.doFetch, now)).catch(isolate('kimi', now)),
        Promise.resolve(geminiAccount(this.home, this.env, this.doFetch, now)).catch(isolate('gemini', now)),
        Promise.resolve(grokAccount(this.home, this.env, this.doFetch, now)).catch(isolate('grok', now)),
        Promise.resolve(zedAccount(this.home, this.env, this.doFetch, now)).catch(isolate('zed', now)),
        Promise.resolve(kiroAccount(this.home, this.env, this.doFetch, now)).catch(isolate('kiro', now)),
        Promise.resolve(codebuffAccount(this.home, this.env, this.doFetch, now)).catch(isolate('codebuff', now)),
        Promise.resolve(factoryAccount(this.home, this.env, this.doFetch, now)).catch(isolate('factory', now)),
        Promise.resolve(copilotAccount(this.home, this.env, this.doFetch, now)).catch(isolate('copilot', now)),
        Promise.resolve(openrouterAccount(this.home, this.env, this.doFetch, now)).catch(isolate('openrouter', now)),
        Promise.resolve(minimaxAccount(this.home, this.env, this.doFetch, now)).catch(isolate('minimax', now)),
      ])
      this.snapshot = { accounts: results }
    })().finally(() => {
      this.lastFetchAt = this.now()
      this.inflight = null
    })
    return this.inflight.then(() => this.snapshot)
  }

  private async fetchGlm(now: number): Promise<QuotaAccount> {
    try {
      const auth = readCodingPlanAuth(this.home, this.env)
      if (!auth) return missing('glm', 'GLM Coding Plan', now)
      const snap = await fetchPlanSnapshot(auth, this.doFetch, now)
      return glmToAccount(snap)
    } catch (err) {
      return {
        kind: 'glm', label: 'GLM Coding Plan', available: false,
        unavailableReason: 'error', error: err instanceof Error ? err.message : String(err),
        planName: null, windows: [], fetchedAt: now, lastSuccessAt: null,
      }
    }
  }
}

const missing = (kind: QuotaAccount['kind'], label: string, now: number): QuotaAccount => ({
  kind, label, available: false, unavailableReason: 'no_credentials', error: null,
  planName: null, windows: [], fetchedAt: now, lastSuccessAt: null,
})

/** provider 隔离：任何未捕获异常都降级成该账号的 error 快照 */
function isolate(kind: QuotaAccount['kind'], now: number): (err: unknown) => QuotaAccount {
  const label = LOADING_ACCOUNTS.find(a => a.kind === kind)?.label ?? kind
  return (err: unknown) => ({
    kind, label, available: false, unavailableReason: 'error',
    error: err instanceof Error ? err.message : String(err),
    planName: null, windows: [], fetchedAt: now, lastSuccessAt: null,
  })
}

const defaultFetch: FetchLike = (url, init) => fetch(url, init)
