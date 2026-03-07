import Fluent

struct CreateRefreshToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("refresh_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime)
            .create()

        // Index on token_hash for fast lookup during refresh
        try await database.schema("refresh_tokens")
            .unique(on: "token_hash")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("refresh_tokens").delete()
    }
}
