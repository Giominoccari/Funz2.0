import Fluent

struct CreatePOINotification: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("poi_notifications")
            .id()
            .field("poi_id", .uuid, .required, .references("pois", "id", onDelete: .cascade))
            .field("forecast_date", .string, .required)
            .field("sent_at", .datetime)
            .unique(on: "poi_id", "forecast_date")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("poi_notifications").delete()
    }
}
