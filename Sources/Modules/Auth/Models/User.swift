import Fluent
import Vapor

/// Fluent model for the `users` table.
/// @unchecked Sendable: required because Fluent property wrappers use internal mutation.
final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @OptionalField(key: "password_hash")
    var passwordHash: String?

    @OptionalField(key: "apple_user_id")
    var appleUserID: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$user)
    var refreshTokens: [RefreshToken]

    init() {}

    init(id: UUID? = nil, email: String, passwordHash: String? = nil, appleUserID: String? = nil) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.appleUserID = appleUserID
    }
}
