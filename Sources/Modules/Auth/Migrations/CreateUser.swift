import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .id()
            .field("email", .string, .required)
            .field("password_hash", .string)
            .field("apple_user_id", .string)
            .field("created_at", .datetime)
            .unique(on: "email")
            .unique(on: "apple_user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users").delete()
    }
}
