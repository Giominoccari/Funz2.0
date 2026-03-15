import Vapor

enum SubscriptionDTO {
    struct StatusResponse: Content {
        let plan: String
        let status: String
        let currentPeriodEnd: Date?
        let entitlements: PlanEntitlements

        init(subscription: Subscription?, entitlements: PlanEntitlements) {
            self.plan = subscription?.plan ?? "free"
            self.status = subscription?.status ?? "active"
            self.currentPeriodEnd = subscription?.currentPeriodEnd
            self.entitlements = entitlements
        }
    }

    struct CheckoutRequest: Content {
        let plan: String
    }

    struct CheckoutResponse: Content {
        let checkoutURL: String
    }
}
