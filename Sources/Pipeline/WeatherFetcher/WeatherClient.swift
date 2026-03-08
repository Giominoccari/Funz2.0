import Foundation

protocol WeatherClient: Sendable {
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData
}
