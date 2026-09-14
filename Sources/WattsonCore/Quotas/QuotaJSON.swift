// Quotas/QuotaJSON.swift — QuotaSnapshot/QuotaAccount → JSON（/api/plan 响应体）。
import Foundation

public func quotaWindowJSON(_ w: QuotaWindow) -> JSON {
    var o: [String: JSON] = [
        "key": .str(w.key),
        "label": .str(w.label),
        "percentage": w.percentage.map(JSON.num) ?? .null,
        "nextResetAt": w.nextResetAt.map(JSON.num) ?? .null,
    ]
    o["usedPercent"] = w.usedPercent.map(JSON.num) ?? .null
    o["total"] = w.total.map(JSON.num) ?? .null
    o["used"] = w.used.map(JSON.num) ?? .null
    o["remaining"] = w.remaining.map(JSON.num) ?? .null
    return .obj(o)
}

public func quotaAccountJSON(_ a: QuotaAccount) -> JSON {
    var o: [String: JSON] = [
        "kind": .str(a.kind.rawValue),
        "label": .str(a.label),
        "available": .bool(a.available),
        "unavailableReason": a.unavailableReason.map(JSON.str) ?? .null,
        "error": a.error.map(JSON.str) ?? .null,
        "planName": a.planName.map(JSON.str) ?? .null,
        "windows": .arr(a.windows.map(quotaWindowJSON)),
        "fetchedAt": .num(a.fetchedAt),
        "lastSuccessAt": a.lastSuccessAt.map(JSON.num) ?? .null,
    ]
    if let rc = a.resetCredits { o["resetCredits"] = .num(rc) }
    if let rc = a.applicableResetCredits { o["applicableResetCredits"] = .num(rc) }
    return .obj(o)
}

public func quotaSnapshotJSON(_ s: QuotaSnapshot) -> JSON {
    .obj(["accounts": .arr(s.accounts.map(quotaAccountJSON))])
}
