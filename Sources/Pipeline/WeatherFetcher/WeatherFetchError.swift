import Foundation

enum WeatherFetchError: Error, Sendable {
    case httpError(statusCode: UInt, latitude: Double, longitude: Double)
    case decodingError(String, latitude: Double, longitude: Double)
    case noData(latitude: Double, longitude: Double)
}
