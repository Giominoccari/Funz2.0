import Vapor

/// Config-driven entitlements for a subscription plan.
/// Add new fields here as gating needs evolve (e.g. mapVariety, apiAccess).
/// All plans are defined in `config/app.yaml` under `subscription.plans`.
struct PlanEntitlements: Codable, Sendable, Content {
    let maxZoom: Int
    let historyDays: Int
    let features: [String]

    /// Default entitlements for unauthenticated or free users.
    static let free = PlanEntitlements(maxZoom: 9, historyDays: 0, features: [])
}

// MARK: - Request storage

struct PlanEntitlementsKey: StorageKey {
    typealias Value = PlanEntitlements
}

extension Request {
    /// The resolved entitlements for the current user's plan.
    /// Falls back to free-tier entitlements if no subscription middleware ran.
    var planEntitlements: PlanEntitlements {
        get { storage[PlanEntitlementsKey.self] ?? .free }
        set { storage[PlanEntitlementsKey.self] = newValue }
    }
}
