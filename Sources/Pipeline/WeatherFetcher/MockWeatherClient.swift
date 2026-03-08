import Foundation

struct MockWeatherClient: WeatherClient {
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData {
        // Deterministic mock: simulate favorable mushroom conditions
        // in central Trentino, drier at edges
        let normalizedLat = (latitude - 45.8) / (46.5 - 45.8)
        let normalizedLon = (longitude - 10.8) / (11.8 - 10.8)

        // Rain peaks in center of bbox
        let distFromCenter = abs(normalizedLat - 0.5) + abs(normalizedLon - 0.5)
        let rain = max(0, 80.0 - distFromCenter * 100.0)

        // Temperature decreases with "altitude" (latitude as proxy)
        let temp = 22.0 - normalizedLat * 10.0

        // Humidity correlated with rain
        let humidity = min(100, 50.0 + rain * 0.5)

        return WeatherData(
            rain14d: rain,
            avgTemperature: temp,
            avgHumidity: humidity
        )
    }
}
