import Foundation

protocol WeatherClient: Sendable {
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData

    /// Fetch raw daily observations for the configured date range.
    func fetchDaily(latitude: Double, longitude: Double) async throws -> [DailyObservation]

    /// Fetch daily observations for a specific date range (for incremental fetching).
    func fetchDaily(latitude: Double, longitude: Double, startDate: String, endDate: String) async throws -> [DailyObservation]

    /// Fetch weather for multiple coordinates in a single API call.
    func fetchBatch(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [WeatherData]

    /// Fetch raw daily observations for multiple coordinates.
    func fetchDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [[DailyObservation]]

    /// Fetch daily observations for multiple coordinates with a specific date range.
    func fetchDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)],
        startDate: String,
        endDate: String
    ) async throws -> [[DailyObservation]]
}

extension WeatherClient {
    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData {
        let daily = try await fetchDaily(latitude: latitude, longitude: longitude)
        return WeatherData.aggregate(from: daily)
    }

    func fetchDaily(latitude: Double, longitude: Double) async throws -> [DailyObservation] {
        // Fallback: wrap aggregate as a single pseudo-observation (lossy)
        let data = try await fetch(latitude: latitude, longitude: longitude)
        return [DailyObservation(date: "", rainMm: data.rain14d, tempMeanC: data.avgTemperature, humidityPct: data.avgHumidity, soilTempC: data.avgSoilTemp7d)]
    }

    func fetchBatch(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [WeatherData] {
        let dailyBatch = try await fetchDailyBatch(coordinates: coordinates)
        return dailyBatch.map { WeatherData.aggregate(from: $0) }
    }

    func fetchDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [[DailyObservation]] {
        var results: [[DailyObservation]] = []
        for coord in coordinates {
            results.append(try await fetchDaily(latitude: coord.latitude, longitude: coord.longitude))
        }
        return results
    }

    func fetchDaily(latitude: Double, longitude: Double, startDate: String, endDate: String) async throws -> [DailyObservation] {
        try await fetchDaily(latitude: latitude, longitude: longitude)
    }

    func fetchDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)],
        startDate: String,
        endDate: String
    ) async throws -> [[DailyObservation]] {
        try await fetchDailyBatch(coordinates: coordinates)
    }
}
