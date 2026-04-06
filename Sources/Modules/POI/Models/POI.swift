import Fluent
import Vapor

/// A user-saved location watched for mushroom forecast notifications.
/// @unchecked Sendable: required because Fluent property wrappers use internal mutation.
final class POI: Model, Content, @unchecked Sendable {
    static let schema = "pois"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "name")
    var name: String

    @Field(key: "latitude")
    var latitude: Double

    @Field(key: "longitude")
    var longitude: Double

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.$user.id = userID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}
