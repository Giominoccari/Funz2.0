import Fluent
import Vapor

/// Fluent model for the `photos` table.
/// @unchecked Sendable: required because Fluent property wrappers use internal mutation.
final class Photo: Model, Content, @unchecked Sendable {
    static let schema = "photos"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "s3_url")
    var s3URL: String

    @OptionalField(key: "species")
    var species: String?

    @OptionalField(key: "notes")
    var notes: String?

    @OptionalField(key: "latitude")
    var latitude: Double?

    @OptionalField(key: "longitude")
    var longitude: Double?

    @OptionalField(key: "taken_at")
    var takenAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        s3URL: String,
        species: String? = nil,
        notes: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        takenAt: Date? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.s3URL = s3URL
        self.species = species
        self.notes = notes
        self.latitude = latitude
        self.longitude = longitude
        self.takenAt = takenAt
    }
}
