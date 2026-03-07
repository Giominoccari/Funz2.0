import Fluent
import Vapor

/// Fluent model for the `refresh_tokens` table.
/// @unchecked Sendable: required because Fluent property wrappers use internal mutation.
final class RefreshToken: Model, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, tokenHash: String, expiresAt: Date) {
        self.id = id
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }
}
