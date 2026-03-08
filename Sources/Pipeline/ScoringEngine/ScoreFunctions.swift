import Foundation

enum ScoreFunctions {
    /// Forest type score: mixed forest is ideal for mushrooms
    static func forestScore(_ type: ForestType) -> Double {
        type.score
    }

    /// Rain score: optimal 40-80mm over 14 days, drops off outside range
    static func rainScore(_ rain14d: Double) -> Double {
        if rain14d <= 0 { return 0.0 }
        if rain14d < 20 { return rain14d / 20.0 * 0.4 }
        if rain14d < 40 { return 0.4 + (rain14d - 20) / 20.0 * 0.6 }
        if rain14d <= 80 { return 1.0 }
        if rain14d <= 120 { return 1.0 - (rain14d - 80) / 40.0 * 0.5 }
        return max(0, 0.5 - (rain14d - 120) / 80.0 * 0.5)
    }

    /// Temperature score: optimal 15-22°C
    static func tempScore(_ avgTemp: Double) -> Double {
        if avgTemp < 5 { return 0.0 }
        if avgTemp < 15 { return (avgTemp - 5) / 10.0 }
        if avgTemp <= 22 { return 1.0 }
        if avgTemp <= 30 { return 1.0 - (avgTemp - 22) / 8.0 }
        return 0.0
    }

    /// Humidity score: higher humidity is better, optimal > 70%
    static func humidityScore(_ avgHumidity: Double) -> Double {
        if avgHumidity < 30 { return 0.0 }
        if avgHumidity < 70 { return (avgHumidity - 30) / 40.0 }
        return 1.0
    }

    /// Altitude score: optimal 400-1200m s.l.m.
    static func altitudeScore(_ altitude: Double) -> Double {
        if altitude < 100 { return 0.1 }
        if altitude < 400 { return 0.1 + (altitude - 100) / 300.0 * 0.9 }
        if altitude <= 1200 { return 1.0 }
        if altitude <= 2000 { return 1.0 - (altitude - 1200) / 800.0 }
        return 0.0
    }

    /// Soil type score: calcareous soils are best for many mushroom species
    static func soilScore(_ type: SoilType) -> Double {
        type.score
    }
}
