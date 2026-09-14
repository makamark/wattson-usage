// Quotas/Poller.swift — 多 provider 订阅额度轮询：单飞 + TTL（5 分钟）；
// 各 provider 相互隔离，任一失败不影响其它；全部失败/无凭据只体现在各自
// account 的 unavailableReason 里。
import Foundation

let PROVIDER_ORDER: [(QuotaKind, String)] = [
    (.glm, "GLM Coding Plan"),
    (.codex, "Codex (ChatGPT)"),
    (.claude, "Claude Code"),
    (.cursor, "Cursor"),
    (.workbuddy, "WorkBuddy"),
    (.trae, "Trae"),
    (.kimi, "Kimi"),
    (.gemini, "Gemini"),
    (.grok, "Grok"),
    (.zed, "Zed"),
    (.kiro, "Kiro"),
    (.codebuff, "Codebuff"),
    (.factory, "Factory"),
    (.copilot, "Copilot"),
    (.openrouter, "OpenRouter"),
    (.minimax, "MiniMax"),
]

public final class QuotaPoller: @unchecked Sendable {
    private let lock = NSLock()
    private var state: QuotaSnapshot
    private var inflight: Task<QuotaSnapshot, Never>?
    private var lastFetchAt = -Double.infinity

    private let home: String
    private let env: [String: String]
    private let doFetch: FetchLike
    private let now: @Sendable () -> Double

    public init(home: String? = nil, env: [String: String]? = nil,
                fetchImpl: FetchLike? = nil, now: (@Sendable () -> Double)? = nil) {
        self.home = home ?? homePath()
        self.env = env ?? ProcessInfo.processInfo.environment
        self.doFetch = fetchImpl ?? makeHTTPFetch()
        self.now = now ?? { Date.nowMs() }
        // loading 占位：首拉完成前 UI 有确定形态
        self.state = QuotaSnapshot(accounts: PROVIDER_ORDER.map {
            QuotaAccount(kind: $0.0, label: $0.1, available: false, unavailableReason: "loading",
                         error: nil, planName: nil, windows: [], fetchedAt: 0, lastSuccessAt: nil)
        })
    }

    /// 最近一轮快照（同步读取：HTTP 服务器与 UI 都用它）
    public var snapshotValue: QuotaSnapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// 拉一轮全部 provider（带 TTL）；绝不抛错
    public func current() async -> QuotaSnapshot {
        lock.lock()
        if let t = inflight {
            lock.unlock()
            return await t.value
        }
        if now() - lastFetchAt < PLAN_TTL_MS {
            lock.unlock()
            return snapshotValue
        }
        let task = Task<QuotaSnapshot, Never> { await self.runRound() }
        inflight = task
        lock.unlock()
        return await task.value
    }

    private func runRound() async -> QuotaSnapshot {
        let n = now()
        // 各 provider 并发拉取，按 PROVIDER_ORDER 顺序回填
        var results = [QuotaAccount?](repeating: nil, count: PROVIDER_ORDER.count)
        await withTaskGroup(of: (Int, QuotaAccount).self) { group in
            for (idx, spec) in PROVIDER_ORDER.enumerated() {
                group.addTask {
                    let account = await self.fetchOne(kind: spec.0, label: spec.1, now: n)
                    return (idx, account)
                }
            }
            for await (idx, account) in group {
                results[idx] = account
            }
        }
        let snapshot = QuotaSnapshot(accounts: results.enumerated().map { idx, account in
            account ?? loadingAccount(PROVIDER_ORDER[idx].0, PROVIDER_ORDER[idx].1, n)
        })
        lock.lock()
        state = snapshot
        lastFetchAt = now()
        inflight = nil
        lock.unlock()
        return snapshot
    }

    private func fetchOne(kind: QuotaKind, label: String, now: Double) async -> QuotaAccount {
        do {
            return try await fetchProvider(kind, home, env, doFetch, now)
        } catch {
            // provider 隔离：任何未捕获异常都降级成该账号的 error 快照
            return QuotaAccount(kind: kind, label: label, available: false,
                                unavailableReason: "error", error: errText(error),
                                planName: nil, windows: [], fetchedAt: now, lastSuccessAt: nil)
        }
    }
}

func loadingAccount(_ kind: QuotaKind, _ label: String, _ now: Double) -> QuotaAccount {
    QuotaAccount(kind: kind, label: label, available: false, unavailableReason: "loading",
                 error: nil, planName: nil, windows: [], fetchedAt: now, lastSuccessAt: nil)
}

/// 单 provider 分发：glm 走 PlanSnapshot（绝对值口径），其余各自模块
func fetchProvider(_ kind: QuotaKind, _ home: String, _ env: [String: String],
                   _ doFetch: FetchLike, _ now: Double) async throws -> QuotaAccount {
    switch kind {
    case .glm:
        guard let auth = readCodingPlanAuth(home, env) else {
            return missingAccount(.glm, "GLM Coding Plan", now)
        }
        let snap = await fetchPlanSnapshot(auth: auth, doFetch: doFetch, now: now)
        return glmToAccount(snap)
    case .codex: return await codexAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .claude: return await claudeAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .cursor: return await cursorAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .workbuddy: return await workbuddyAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .trae: return await traeAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .kimi: return await kimiAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .gemini: return await geminiAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .grok: return await grokAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .zed: return await zedAccount(home, env: env, doFetch: doFetch, now: now)
    case .kiro: return await kiroAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .codebuff: return await codebuffAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .factory: return await factoryAccount(home: home, env: env, doFetch: doFetch, now: now)
    case .copilot: return await copilotAccount(home, env: env, doFetch: doFetch, now: now)
    case .openrouter: return await openrouterAccount(home, env: env, doFetch: doFetch, now: now)
    case .minimax: return await minimaxAccount(home, env: env, doFetch: doFetch, now: now)
    }
}
