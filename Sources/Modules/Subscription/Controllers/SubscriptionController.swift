import Fluent
import Logging
import Vapor

struct SubscriptionController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.subscription")

    func boot(routes: RoutesBuilder) throws {
        let sub = routes.grouped("subscription")

        // Protected: requires JWT + resolves entitlements
        let protected = sub.grouped(JWTAuthMiddleware(), SubscriptionMiddleware())
        protected.get("status", use: getStatus)
        protected.post("checkout", use: createCheckout)

        // Webhook: no JWT, verified via Stripe signature
        sub.post("webhook", use: handleWebhook)
    }

    // MARK: - GET /subscription/status

    @Sendable
    func getStatus(req: Request) async throws -> SubscriptionDTO.StatusResponse {
        let payload = try req.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized)
        }

        let subscription = try await Subscription.query(on: req.db)
            .filter(\.$user.$id == userID)
            .first()

        return SubscriptionDTO.StatusResponse(
            subscription: subscription,
            entitlements: req.planEntitlements
        )
    }

    // MARK: - POST /subscription/checkout

    @Sendable
    func createCheckout(req: Request) async throws -> SubscriptionDTO.CheckoutResponse {
        let payload = try req.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized)
        }

        let body = try req.content.decode(SubscriptionDTO.CheckoutRequest.self)
        let config = try ConfigLoader.load()

        guard let planEntitlements = config.subscription.plans[body.plan] else {
            throw Abort(.badRequest, reason: "Unknown plan: \(body.plan)")
        }
        _ = planEntitlements // validates plan exists in config

        guard let priceID = config.subscription.stripePriceIDs[body.plan] else {
            throw Abort(.badRequest, reason: "No Stripe price configured for plan: \(body.plan)")
        }

        // Look up user email for Stripe
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "User not found.")
        }

        let stripe = try StripeClient()
        let checkoutURL = try await stripe.createCheckoutSession(
            customerEmail: user.email,
            priceID: priceID,
            successURL: config.subscription.checkoutSuccessURL,
            cancelURL: config.subscription.checkoutCancelURL,
            client: req.client
        )

        Self.logger.info("Checkout session created", metadata: [
            "user_id": "\(userID)",
            "plan": "\(body.plan)",
        ])

        return SubscriptionDTO.CheckoutResponse(checkoutURL: checkoutURL)
    }

    // MARK: - POST /subscription/webhook

    @Sendable
    func handleWebhook(req: Request) async throws -> HTTPStatus {
        // Verify Stripe signature
        guard let signature = req.headers.first(name: "Stripe-Signature") else {
            throw Abort(.badRequest, reason: "Missing Stripe-Signature header.")
        }

        guard let webhookSecret = Environment.get("STRIPE_WEBHOOK_SECRET") else {
            Self.logger.critical("STRIPE_WEBHOOK_SECRET not configured")
            throw Abort(.internalServerError)
        }

        guard let body = req.body.data else {
            throw Abort(.badRequest, reason: "Empty request body.")
        }

        try StripeClient.verifyWebhookSignature(
            payload: body,
            signature: signature,
            secret: webhookSecret
        )

        // Parse event
        let event = try req.content.decode(StripeEvent.self)

        Self.logger.info("Stripe webhook received", metadata: [
            "type": "\(event.type)",
            "id": "\(event.id)",
        ])

        switch event.type {
        case "checkout.session.completed":
            try await handleCheckoutCompleted(event: event, db: req.db)
        case "customer.subscription.updated":
            try await handleSubscriptionUpdated(event: event, db: req.db)
        case "customer.subscription.deleted":
            try await handleSubscriptionDeleted(event: event, db: req.db)
        default:
            Self.logger.trace("Unhandled webhook event type", metadata: ["type": "\(event.type)"])
        }

        return .ok
    }

    // MARK: - Webhook Handlers

    private func handleCheckoutCompleted(event: StripeEvent, db: any Database) async throws {
        let obj = event.data.object
        guard let customerEmail = obj.customerEmail,
              let stripeCustomerID = obj.customer,
              let stripeSubID = obj.subscription
        else {
            Self.logger.warning("checkout.session.completed missing fields", metadata: ["event_id": "\(event.id)"])
            return
        }

        // Find user by email
        guard let user = try await User.query(on: db)
            .filter(\.$email == customerEmail)
            .first()
        else {
            Self.logger.warning("No user found for checkout email", metadata: ["email": "\(customerEmail)"])
            return
        }

        // Upsert subscription
        if let existing = try await Subscription.query(on: db)
            .filter(\.$user.$id == user.id!)
            .first()
        {
            existing.plan = "pro"
            existing.stripeCustomerID = stripeCustomerID
            existing.stripeSubscriptionID = stripeSubID
            existing.status = "active"
            existing.currentPeriodEnd = .distantFuture
            try await existing.save(on: db)
        } else {
            let sub = Subscription(
                userID: user.id!,
                plan: "pro",
                status: "active"
            )
            sub.stripeCustomerID = stripeCustomerID
            sub.stripeSubscriptionID = stripeSubID
            try await sub.save(on: db)
        }

        Self.logger.info("Subscription activated via checkout", metadata: [
            "user_id": "\(user.id!)",
            "stripe_customer": "\(stripeCustomerID)",
        ])
    }

    private func handleSubscriptionUpdated(event: StripeEvent, db: any Database) async throws {
        let obj = event.data.object
        guard let stripeSubID = obj.id else { return }

        guard let subscription = try await Subscription.query(on: db)
            .filter(\.$stripeSubscriptionID == stripeSubID)
            .first()
        else {
            Self.logger.warning("Subscription not found for update", metadata: ["stripe_sub_id": "\(stripeSubID)"])
            return
        }

        if let status = obj.status {
            subscription.status = status
        }
        if let periodEnd = obj.currentPeriodEnd {
            subscription.currentPeriodEnd = Date(timeIntervalSince1970: TimeInterval(periodEnd))
        }

        try await subscription.save(on: db)

        Self.logger.info("Subscription updated", metadata: [
            "stripe_sub_id": "\(stripeSubID)",
            "status": "\(subscription.status)",
        ])
    }

    private func handleSubscriptionDeleted(event: StripeEvent, db: any Database) async throws {
        let obj = event.data.object
        guard let stripeSubID = obj.id else { return }

        guard let subscription = try await Subscription.query(on: db)
            .filter(\.$stripeSubscriptionID == stripeSubID)
            .first()
        else { return }

        subscription.status = "canceled"
        subscription.plan = "free"
        try await subscription.save(on: db)

        Self.logger.info("Subscription canceled", metadata: [
            "stripe_sub_id": "\(stripeSubID)",
            "user_id": "\(subscription.$user.id)",
        ])
    }
}

// MARK: - Stripe Event Models

struct StripeEvent: Content {
    let id: String
    let type: String
    let data: StripeEventData
}

struct StripeEventData: Content {
    let object: StripeEventObject
}

struct StripeEventObject: Content {
    let id: String?
    let customer: String?
    let customerEmail: String?
    let subscription: String?
    let status: String?
    let currentPeriodEnd: Int?

    enum CodingKeys: String, CodingKey {
        case id, customer, subscription, status
        case customerEmail = "customer_email"
        case currentPeriodEnd = "current_period_end"
    }
}
