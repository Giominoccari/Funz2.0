import Fluent

struct CreatePOI: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("pois")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("latitude", .double, .required)
            .field("longitude", .double, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("pois").delete()
    }
}
