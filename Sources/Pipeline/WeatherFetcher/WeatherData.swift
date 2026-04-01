import Foundation

/// A single day's weather observation at a grid point.
struct DailyObservation: Sendable, Codable, Equatable {
    let date: String        // "YYYY-MM-DD"
    let rainMm: Double      // rain_sum for that day (mm)
    let tempMeanC: Double   // temperature_2m_mean (°C)
    let humidityPct: Double // relative_humidity_2m_mean (%)
    let soilTempC: Double   // soil_temperature_0_to_7cm daily mean (°C)
}

/// Aggregated weather data consumed by ScoringEngine.
struct WeatherData: Sendable, Codable {
    /// Cumulative rainfall over the last 14 days (mm)
    let rain14d: Double
    /// Maximum rainfall over any 2 consecutive days in the 14-day window (mm)
    let maxRain2d: Double
    /// Average temperature over the last 7 days (°C)
    let avgTemperature: Double
    /// Average relative humidity over the last 7 days (%)
    let avgHumidity: Double
    /// Average soil temperature (0-7cm depth) over the last 7 days (°C)
    let avgSoilTemp7d: Double

    /// Aggregate daily observations into scoring-ready weather data.
    /// Observations must be sorted by date ascending.
    static func aggregate(from observations: [DailyObservation]) -> WeatherData {
        let rain14d = observations.map(\.rainMm).reduce(0, +)

        // Max 2-consecutive-day rainfall (rain trigger index)
        var maxRain2d = observations.first?.rainMm ?? 0
        for i in 1..<observations.count {
            let twoDay = observations[i - 1].rainMm + observations[i].rainMm
            maxRain2d = max(maxRain2d, twoDay)
        }

        let last7Temps = observations.suffix(7).map(\.tempMeanC)
        let avgTemperature = last7Temps.isEmpty
            ? 0 : last7Temps.reduce(0, +) / Double(last7Temps.count)

        let last7Humidity = observations.suffix(7).map(\.humidityPct)
        let avgHumidity = last7Humidity.isEmpty
            ? 0 : last7Humidity.reduce(0, +) / Double(last7Humidity.count)

        let last7SoilTemp = observations.suffix(7).map(\.soilTempC)
        let avgSoilTemp7d = last7SoilTemp.isEmpty
            ? 0 : last7SoilTemp.reduce(0, +) / Double(last7SoilTemp.count)

        return WeatherData(
            rain14d: rain14d,
            maxRain2d: maxRain2d,
            avgTemperature: avgTemperature,
            avgHumidity: avgHumidity,
            avgSoilTemp7d: avgSoilTemp7d
        )
    }
}
