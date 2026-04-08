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

    /// Rain trigger score: rewards concentrated rain events (max 2-day rainfall).
    /// A sharp rain event followed by drying triggers fruiting far better than steady drizzle.
    static func rainTriggerScore(_ maxRain2d: Double) -> Double {
        if maxRain2d < 5 { return 0.0 }
        if maxRain2d < 10 { return (maxRain2d - 5) / 5.0 * 0.5 }
        if maxRain2d < 25 { return 0.5 + (maxRain2d - 10) / 15.0 * 0.5 }
        if maxRain2d <= 50 { return 1.0 }
        if maxRain2d <= 80 { return 1.0 - (maxRain2d - 50) / 30.0 * 0.3 }
        return 0.4
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

    /// Soil temperature score: mycelial activity requires warm soil at 0-7cm depth.
    /// Used as a multiplicative modifier — floor of 0.20 so that cold soil suppresses
    /// but does not eliminate scores (mycelium remains present and semi-active below 6°C).
    static func soilTempScore(_ avgSoilTemp7d: Double) -> Double {
        if avgSoilTemp7d < 4 { return 0.20 }
        if avgSoilTemp7d < 8 { return 0.20 + (avgSoilTemp7d - 4) / 4.0 * 0.45 }
        if avgSoilTemp7d < 12 { return 0.65 + (avgSoilTemp7d - 8) / 4.0 * 0.35 }
        if avgSoilTemp7d <= 22 { return 1.0 }
        if avgSoilTemp7d <= 28 { return 1.0 - (avgSoilTemp7d - 22) / 6.0 * 0.6 }
        return 0.20
    }

    /// Altitude score with seasonal adjustment: optimal altitude band shifts by season.
    /// - Spring (May–Jun): 300–1000m (thermophilic species at lower elevations)
    /// - Summer (Jul–Aug): 700–1600m (classic high-altitude flush)
    /// - Autumn (Sep–Oct): 400–1400m (main season, broad range)
    /// - Off-season: uses the static 400–1800m band as fallback
    static func altitudeScore(_ altitude: Double, dayOfYear: Int) -> Double {
        let (optLow, optHigh) = seasonalAltitudeBand(dayOfYear: dayOfYear)

        // Below minimum viable altitude
        if altitude < 50 { return 0.05 }

        // Ramp up to optimal band
        let rampLow = max(50, optLow - 200) // start ramping 200m below optimal
        if altitude < optLow {
            if altitude < rampLow { return 0.05 + (altitude - 50) / max(1, rampLow - 50) * 0.25 }
            return 0.30 + (altitude - rampLow) / max(1, Double(optLow) - rampLow) * 0.70
        }

        // In optimal band
        if altitude <= Double(optHigh) { return 1.0 }

        // Ramp down above optimal band
        let rampHigh = optHigh + 400 // decline over 400m above optimal
        if altitude <= Double(rampHigh) {
            return 1.0 - (altitude - Double(optHigh)) / Double(rampHigh - optHigh) * 0.9
        }

        return 0.1
    }

    /// Returns the seasonal optimal altitude band (low, high) in meters.
    private static func seasonalAltitudeBand(dayOfYear: Int) -> (low: Double, high: Int) {
        // Seasonal anchor points (mid-month day-of-year values)
        // May 15 = 135, Jul 15 = 196, Sep 15 = 258, Nov 15 = 319
        struct Band {
            let day: Int
            let low: Double
            let high: Int
        }
        let bands: [Band] = [
            Band(day: 135, low: 300, high: 1000),   // May — spring
            Band(day: 166, low: 400, high: 1200),   // Jun — late spring
            Band(day: 196, low: 700, high: 1600),   // Jul — summer peak
            Band(day: 227, low: 700, high: 1600),   // Aug — summer peak
            Band(day: 258, low: 400, high: 1400),   // Sep — autumn
            Band(day: 288, low: 400, high: 1200),   // Oct — late autumn
        ]

        // Off-season fallback (Nov–Apr): use wide band
        let d = dayOfYear
        if d < bands.first!.day || d > bands.last!.day {
            return (low: 400, high: 1800)
        }

        // Find surrounding bands and interpolate
        for i in 0..<(bands.count - 1) {
            if d >= bands[i].day && d <= bands[i + 1].day {
                let t = Double(d - bands[i].day) / Double(bands[i + 1].day - bands[i].day)
                let low = bands[i].low + t * (bands[i + 1].low - bands[i].low)
                let high = bands[i].high + Int(t * Double(bands[i + 1].high - bands[i].high))
                return (low: low, high: high)
            }
        }

        return (low: 400, high: 1800)
    }

    /// Soil type score: mixed humus-rich soils at pH 5.5-6.5 are ideal for Porcini
    static func soilScore(_ type: SoilType) -> Double {
        type.score
    }

    /// Aspect score: north-facing slopes retain moisture (best for mushrooms), south-facing dry out
    static func aspectScore(_ aspect: Double) -> Double {
        // aspect=0 from GDAL means flat terrain or missing data — use neutral score
        if aspect == 0 { return 0.5 }
        let normalized = aspect.truncatingRemainder(dividingBy: 360)
        let a = normalized < 0 ? normalized + 360 : normalized
        let radians = a * .pi / 180.0
        // cos(0)=1 for North, cos(π)=-1 for South → mapped to [0.30, 1.0]
        return 0.65 + 0.35 * cos(radians)
    }

    /// Season score: soft calendar-based gate for Porcini fruiting phenology.
    /// Based on documented Italian phenology: B. aereus flushes in April in southern
    /// and coastal zones; B. edulis main season May–October.
    /// Floor of 0.15 allows exceptional warm-winter finds (e.g., B. aereus Mediterranean).
    static func seasonScore(dayOfYear: Int) -> Double {
        let d = dayOfYear
        // Dec–Feb (335–59): deep winter
        if d >= 335 || d <= 59 { return 0.15 }
        // March (60–90): very early spring
        if d <= 90 { return 0.15 + (Double(d - 60) / 30.0) * 0.15 }
        // April (91–120): early flushes documented (B. aereus, low-altitude B. edulis)
        if d <= 120 { return 0.30 + (Double(d - 91) / 30.0) * 0.30 }
        // May (121–152): spring building
        if d <= 152 { return 0.60 + (Double(d - 121) / 32.0) * 0.40 }
        // Jun–Oct (153–304): prime season
        if d <= 304 { return 1.0 }
        // Nov (305–334): late autumn decline
        return 1.0 - (Double(d - 305) / 30.0) * 0.75
    }
}
