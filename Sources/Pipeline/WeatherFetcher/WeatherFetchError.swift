import Foundation

enum WeatherFetchError: Error, Sendable {
    case httpError(statusCode: UInt, latitude: Double, longitude: Double)
    case decodingError(String, latitude: Double, longitude: Double)
    case noData(latitude: Double, longitude: Double)
    /// Open-Meteo daily API quota exhausted — no point retrying until midnight UTC.
    case dailyQuotaExceeded
}
