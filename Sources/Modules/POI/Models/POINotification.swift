import Fluent
import Vapor

/// Tracks which (poi, forecastDate, sentDate) tuples have already had notifications sent.
/// The unique key includes sentDate (YYYY-MM-DD, Rome timezone) so the same forecast
/// date can be re-notified on different calendar days as the date approaches.
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

    /// The calendar day (Rome timezone) on which this notification was sent (YYYY-MM-DD).
    /// Combined with forecastDate, prevents duplicate sends within the same day.
    @Field(key: "sent_date")
    var sentDate: String

    /// Forecast score (0.0–1.0) at the time this notification was sent.
    /// Used on the next daily run to detect whether conditions improved or worsened.
    @OptionalField(key: "score")
    var score: Double?

    @Timestamp(key: "sent_at", on: .create)
    var sentAt: Date?

    init() {}

    init(poiID: UUID, forecastDate: String, sentDate: String, score: Double) {
        self.$poi.id = poiID
        self.forecastDate = forecastDate
        self.sentDate = sentDate
        self.score = score
    }
}
