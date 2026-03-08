import Fluent

struct CreatePhoto: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("photos")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("s3_url", .string, .required)
            .field("species", .string)
            .field("notes", .string)
            .field("latitude", .double)
            .field("longitude", .double)
            .field("taken_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("photos").delete()
    }
}
