import Fluent

/// Adds device_token column to users (for APNs push notifications).
struct AddDeviceToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("device_token", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("device_token")
            .update()
    }
}
