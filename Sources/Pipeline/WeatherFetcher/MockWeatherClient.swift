import Foundation

struct MockWeatherClient: WeatherClient {
    /// Bounding box used to normalize coordinates. Defaults to Italy.
    private let bbox: BoundingBox
    /// Target date for the mock data. Dates are computed relative to this.
    private let targetDate: String

    init(bbox: BoundingBox = .italy, targetDate: String = "2026-03-25") {
        self.bbox = bbox
        self.targetDate = targetDate
    }

    func fetchDaily(latitude: Double, longitude: Double) async throws -> [DailyObservation] {
        try await fetchDaily(latitude: latitude, longitude: longitude, startDate: computeStartDate(), endDate: targetDate)
    }

    func fetchDaily(latitude: Double, longitude: Double, startDate: String, endDate: String) async throws -> [DailyObservation] {
        let dates = CachedWeatherClient.generateDateRange(from: startDate, to: endDate)
        guard !dates.isEmpty else { return [] }

        // Deterministic mock: simulate favorable mushroom conditions
        // in center of bbox, drier at edges
        let normalizedLat = (latitude - bbox.minLat) / (bbox.maxLat - bbox.minLat)
        let normalizedLon = (longitude - bbox.minLon) / (bbox.maxLon - bbox.minLon)

        // Rain peaks in center of bbox
        let distFromCenter = abs(normalizedLat - 0.5) + abs(normalizedLon - 0.5)
        let totalRain14d = max(0, 80.0 - distFromCenter * 100.0)

        // Temperature decreases with "altitude" (latitude as proxy)
        let temp = 22.0 - normalizedLat * 10.0

        // Soil temp: damped version of air temp (less extreme, lagged)
        let soilTemp = temp * 0.85 + 2.0

        // Humidity correlated with rain
        let humidity = min(100, 50.0 + totalRain14d * 0.5)

        // Generate daily observations with realistic rain variation:
        // simulate a trigger event (heavy rain on days 3-4) followed by lighter days
        return dates.enumerated().map { (i, date) in
            let dayFraction: Double
            switch i {
            case 3:  dayFraction = 0.25  // trigger day 1
            case 4:  dayFraction = 0.20  // trigger day 2
            case 5:  dayFraction = 0.10  // tapering
            case 6:  dayFraction = 0.08
            case 7:  dayFraction = 0.07
            default: dayFraction = 0.30 / 9.0  // remaining rain spread across other days
            }
            let dailyRain = totalRain14d * dayFraction

            // Deterministic small daily variation using sin wave
            let variation = sin(Double(i) * 0.7) * 1.5

            return DailyObservation(
                date: date,
                rainMm: dailyRain,
                tempMeanC: temp + variation,
                humidityPct: min(100, humidity + (dailyRain > 5 ? 15 : 0)),
                soilTempC: soilTemp + variation * 0.3
            )
        }
    }

    private func computeStartDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let end = formatter.date(from: targetDate),
              let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -13, to: end) else {
            return targetDate
        }
        return formatter.string(from: start)
    }
}
