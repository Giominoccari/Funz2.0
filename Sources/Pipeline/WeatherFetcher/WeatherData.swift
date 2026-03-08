import Foundation

struct WeatherData: Sendable {
    /// Cumulative rainfall over the last 14 days (mm)
    let rain14d: Double
    /// Average temperature over the last 7 days (°C)
    let avgTemperature: Double
    /// Average relative humidity over the last 7 days (%)
    let avgHumidity: Double
}
