import Foundation

struct MockWeatherClient: WeatherClient {
    /// Bounding box used to normalize coordinates. Defaults to Italy.
    private let bbox: BoundingBox

    init(bbox: BoundingBox = .italy) {
        self.bbox = bbox
    }

    func fetchDaily(latitude: Double, longitude: Double) async throws -> [DailyObservation] {
        // Deterministic mock: simulate favorable mushroom conditions
        // in center of bbox, drier at edges
        let normalizedLat = (latitude - bbox.minLat) / (bbox.maxLat - bbox.minLat)
        let normalizedLon = (longitude - bbox.minLon) / (bbox.maxLon - bbox.minLon)

        // Rain peaks in center of bbox
        let distFromCenter = abs(normalizedLat - 0.5) + abs(normalizedLon - 0.5)
        let dailyRain = max(0, (80.0 - distFromCenter * 100.0) / 14.0)

        // Temperature decreases with "altitude" (latitude as proxy)
        let temp = 22.0 - normalizedLat * 10.0

        // Humidity correlated with rain
        let humidity = min(100, 50.0 + dailyRain * 14.0 * 0.5)

        // Generate 14 daily observations
        return (0..<14).map { i in
            DailyObservation(
                date: "2026-03-\(String(format: "%02d", 12 + i))",
                rainMm: dailyRain,
                tempMeanC: temp,
                humidityPct: humidity
            )
        }
    }
}
