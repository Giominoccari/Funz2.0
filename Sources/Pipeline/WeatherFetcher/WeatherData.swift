import Foundation

/// A single day's weather observation at a grid point.
struct DailyObservation: Sendable, Codable, Equatable {
    let date: String        // "YYYY-MM-DD"
    let rainMm: Double      // rain_sum for that day (mm)
    let tempMeanC: Double   // temperature_2m_mean (°C)
    let humidityPct: Double // relative_humidity_2m_mean (%)
}

/// Aggregated weather data consumed by ScoringEngine.
struct WeatherData: Sendable, Codable {
    /// Cumulative rainfall over the last 14 days (mm)
    let rain14d: Double
    /// Average temperature over the last 7 days (°C)
    let avgTemperature: Double
    /// Average relative humidity over the last 7 days (%)
    let avgHumidity: Double

    /// Aggregate daily observations into scoring-ready weather data.
    /// Observations must be sorted by date ascending.
    static func aggregate(from observations: [DailyObservation]) -> WeatherData {
        let rain14d = observations.map(\.rainMm).reduce(0, +)

        let last7Temps = observations.suffix(7).map(\.tempMeanC)
        let avgTemperature = last7Temps.isEmpty
            ? 0 : last7Temps.reduce(0, +) / Double(last7Temps.count)

        let last7Humidity = observations.suffix(7).map(\.humidityPct)
        let avgHumidity = last7Humidity.isEmpty
            ? 0 : last7Humidity.reduce(0, +) / Double(last7Humidity.count)

        return WeatherData(
            rain14d: rain14d,
            avgTemperature: avgTemperature,
            avgHumidity: avgHumidity
        )
    }
}
