import Fluent

struct AddUserProfileFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("display_name", .string)
            .field("bio", .string)
            .field("photo_url", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("display_name")
            .deleteField("bio")
            .deleteField("photo_url")
            .update()
    }
}
