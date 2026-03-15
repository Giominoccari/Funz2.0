import Fluent

struct CreateSubscription: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("subscriptions")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("plan", .string, .required)
            .field("stripe_customer_id", .string)
            .field("stripe_subscription_id", .string)
            .field("status", .string, .required)
            .field("current_period_end", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .unique(on: "stripe_customer_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("subscriptions").delete()
    }
}
