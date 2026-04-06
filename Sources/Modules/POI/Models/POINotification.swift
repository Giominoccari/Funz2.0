import Fluent
import Vapor

/// Tracks which (poi, forecastDate) pairs have already had notifications sent,
/// preventing duplicate pushes for the same spot on the same day.
/// @unchecked Sendable: required because Fluent property wrappers use internal mutation.
final class POINotification: Model, Content, @unchecked Sendable {
    static let schema = "poi_notifications"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "poi_id")
    var poi: POI

    /// The forecast date this notification refers to (YYYY-MM-DD).
    @Field(key: "forecast_date")
    var forecastDate: String

    @Timestamp(key: "sent_at", on: .create)
    var sentAt: Date?

    init() {}

    init(poiID: UUID, forecastDate: String) {
        self.$poi.id = poiID
        self.forecastDate = forecastDate
    }
}
