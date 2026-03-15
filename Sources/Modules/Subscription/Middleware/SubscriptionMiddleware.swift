import Fluent
import Logging
import Vapor

/// Loads the authenticated user's subscription and resolves plan entitlements
/// from config. Attach after `JWTAuthMiddleware` on routes that need tier gating.
///
/// On success, `req.planEntitlements` is populated for downstream handlers.
/// If no subscription exists, the user gets free-tier entitlements.
struct SubscriptionMiddleware: AsyncMiddleware, Sendable {
    private static let logger = Logger(label: "funghi.subscription")

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let payload = try request.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized, reason: "Invalid user ID in token.")
        }

        // Load subscription from DB
        let subscription = try await Subscription.query(on: request.db)
            .filter(\.$user.$id == userID)
            .first()

        // Resolve plan name
        let planName: String
        if let sub = subscription, sub.isActive {
            planName = sub.plan
        } else {
            planName = "free"
        }

        // Look up entitlements from config
        let config = try ConfigLoader.load()
        let entitlements = config.subscription.plans[planName] ?? .free

        request.planEntitlements = entitlements

        Self.logger.trace("Entitlements resolved", metadata: [
            "user_id": "\(userID)",
            "plan": "\(planName)",
            "max_zoom": "\(entitlements.maxZoom)",
        ])

        return try await next.respond(to: request)
    }
}
