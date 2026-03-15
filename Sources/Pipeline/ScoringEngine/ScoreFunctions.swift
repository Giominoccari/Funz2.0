import Foundation

enum ScoreFunctions {
    /// Forest type score: mixed forests are ideal, both coniferous and broadleaf host Porcini
    static func forestScore(_ type: ForestType) -> Double {
        type.score
    }

    /// Rain score: optimal 50-90mm over 14 days for Porcini fruiting
    static func rainScore(_ rain14d: Double) -> Double {
        if rain14d <= 0 { return 0.0 }
        if rain14d < 15 { return rain14d / 15.0 * 0.2 }
        if rain14d < 30 { return 0.2 + (rain14d - 15) / 15.0 * 0.4 }
        if rain14d < 50 { return 0.6 + (rain14d - 30) / 20.0 * 0.4 }
        if rain14d <= 90 { return 1.0 }
        if rain14d <= 130 { return 1.0 - (rain14d - 90) / 40.0 * 0.4 }
        if rain14d <= 180 { return 0.6 - (rain14d - 130) / 50.0 * 0.5 }
        return 0.1
    }

    /// Temperature score: optimal 12-20°C for Porcini (summer + autumn range)
    static func tempScore(_ avgTemp: Double) -> Double {
        if avgTemp < 4 { return 0.0 }
        if avgTemp < 8 { return (avgTemp - 4) / 4.0 * 0.7 }
        if avgTemp < 12 { return 0.7 + (avgTemp - 8) / 4.0 * 0.3 }
        if avgTemp <= 20 { return 1.0 }
        if avgTemp <= 26 { return 1.0 - (avgTemp - 20) / 6.0 * 0.7 }
        if avgTemp <= 30 { return 0.3 - (avgTemp - 26) / 4.0 * 0.3 }
        return 0.0
    }

    /// Humidity score: higher humidity is better, optimal > 70%
    static func humidityScore(_ avgHumidity: Double) -> Double {
        if avgHumidity < 30 { return 0.0 }
        if avgHumidity < 70 { return (avgHumidity - 30) / 40.0 }
        return 1.0
    }

    /// Altitude score: optimal 400-1800m, Porcini found up to 2400m in Alps
    static func altitudeScore(_ altitude: Double) -> Double {
        if altitude < 50 { return 0.05 }
        if altitude < 200 { return 0.05 + (altitude - 50) / 150.0 * 0.25 }
        if altitude < 400 { return 0.30 + (altitude - 200) / 200.0 * 0.70 }
        if altitude <= 1800 { return 1.0 }
        if altitude <= 2400 { return 1.0 - (altitude - 1800) / 600.0 * 0.9 }
        return 0.1
    }

    /// Soil type score: mixed humus-rich soils at pH 5.5-6.5 are ideal for Porcini
    static func soilScore(_ type: SoilType) -> Double {
        type.score
    }

    /// Aspect score: north-facing slopes retain moisture (best for mushrooms), south-facing dry out
    static func aspectScore(_ aspect: Double) -> Double {
        // aspect=0 from GDAL means flat terrain
        if aspect == 0 { return 0.7 }
        let normalized = aspect.truncatingRemainder(dividingBy: 360)
        let a = normalized < 0 ? normalized + 360 : normalized
        let radians = a * .pi / 180.0
        // cos(0)=1 for North, cos(π)=-1 for South → mapped to [0.30, 1.0]
        return 0.65 + 0.35 * cos(radians)
    }
}
