import Fluent
import Vapor

/// Fluent model for the `subscriptions` table.
/// @unchecked Sendable: required because Fluent property wrappers use internal mutation.
final class Subscription: Model, Content, @unchecked Sendable {
    static let schema = "subscriptions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "plan")
    var plan: String

    @OptionalField(key: "stripe_customer_id")
    var stripeCustomerID: String?

    @OptionalField(key: "stripe_subscription_id")
    var stripeSubscriptionID: String?

    @Field(key: "status")
    var status: String

    @Field(key: "current_period_end")
    var currentPeriodEnd: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        plan: String = "free",
        status: String = "active",
        currentPeriodEnd: Date = .distantFuture
    ) {
        self.id = id
        self.$user.id = userID
        self.plan = plan
        self.status = status
        self.currentPeriodEnd = currentPeriodEnd
    }

    /// Whether this subscription grants active entitlements.
    var isActive: Bool {
        status == "active" && currentPeriodEnd > Date()
    }
}
