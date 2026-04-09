import Foundation

struct ScoringEngine: Sendable {
    let weights: ScoringWeights

    struct Input: Sendable {
        let point: GridPoint
        let weather: WeatherData
        let dayOfYear: Int
    }

    struct Result: Sendable {
        let latitude: Double
        let longitude: Double
        let score: Double
        let baseScore: Double
        let weatherScore: Double
    }

    func score(_ input: Input) -> Result {
        // Static base score — habitat suitability
        let fs = ScoreFunctions.forestScore(input.point.forestType)
        let als = ScoreFunctions.altitudeScore(input.point.altitude, dayOfYear: input.dayOfYear)
        let ss = ScoreFunctions.soilScore(input.point.soilType)
        let asp = ScoreFunctions.aspectScore(input.point.aspect)

        let bw = weights.base
        let baseScore = bw.forest * fs + bw.altitude * als + bw.soil * ss + bw.aspect * asp

        // Phenological weather score — fruiting conditions
        let rs = ScoreFunctions.rainScore(input.weather.rain14d)
        let trs = ScoreFunctions.rainTriggerScore(input.weather.maxRain2d)
        let ts = ScoreFunctions.tempScore(input.weather.avgTemperature)
        let hs = ScoreFunctions.humidityScore(input.weather.avgHumidity)
        let sts = ScoreFunctions.soilTempScore(input.weather.avgSoilTemp7d)

        let ww = weights.weather
        let rawWeather = ww.rain14d * rs + ww.rainTrigger * trs + ww.temperature * ts
        let humidityMultiplier = weights.humidityMultiplierMin
            + (1.0 - weights.humidityMultiplierMin) * hs
        let soilTempMultiplier = sts
        let weatherScore = rawWeather * humidityMultiplier * soilTempMultiplier

        // Habitat is a prerequisite, not an equal driver: sqrt softens the gate so
        // moderate habitat (0.5) gives 0.71× rather than 0.50× on the weather signal.
        // No habitat (0.0) still produces 0. Strong habitat (1.0) still gives full weight.
        // Season multiplier applied last — it is a calendar-based biological gate.
        let product = baseScore.squareRoot() * weatherScore
        let seasonMultiplier = ScoreFunctions.seasonScore(dayOfYear: input.dayOfYear)
        let finalScore = min(1.0, max(0.0, product * seasonMultiplier))

        return Result(
            latitude: input.point.latitude,
            longitude: input.point.longitude,
            score: finalScore,
            baseScore: baseScore,
            weatherScore: weatherScore
        )
    }

    func scoreBatch(_ inputs: [Input]) -> [Result] {
        inputs.map { score($0) }
    }

    // MARK: - Diagnostic breakdown

    /// Full per-component breakdown for a single point. Used by scoring diagnostics
    /// to log representative samples without bloating the main `Result` array.
    struct Breakdown: Sendable {
        // Geo inputs
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let forestType: String
        let soilType: String
        let aspect: Double
        // Weather inputs (from the interpolated WeatherData for this point)
        let rain14d: Double
        let maxRain2d: Double
        let avgTemperature: Double
        let avgHumidity: Double
        let avgSoilTemp7d: Double
        // Base score components
        let forestScore: Double
        let altitudeScore: Double
        let soilScore: Double
        let aspectScore: Double
        let baseScore: Double
        // Weather score components
        let rainScore: Double
        let rainTriggerScore: Double
        let tempScore: Double
        let humidityScore: Double
        let soilTempScore: Double
        let humidityMultiplier: Double
        let rawWeatherScore: Double
        let weatherScore: Double
        // Final
        let seasonMultiplier: Double
        let sqrtBaseScore: Double
        let finalScore: Double
    }

    func diagnose(_ input: Input) -> Breakdown {
        let p = input.point
        let w = input.weather

        let fs  = ScoreFunctions.forestScore(p.forestType)
        let als = ScoreFunctions.altitudeScore(p.altitude, dayOfYear: input.dayOfYear)
        let ss  = ScoreFunctions.soilScore(p.soilType)
        let asp = ScoreFunctions.aspectScore(p.aspect)

        let bw = weights.base
        let base = bw.forest * fs + bw.altitude * als + bw.soil * ss + bw.aspect * asp

        let rs  = ScoreFunctions.rainScore(w.rain14d)
        let trs = ScoreFunctions.rainTriggerScore(w.maxRain2d)
        let ts  = ScoreFunctions.tempScore(w.avgTemperature)
        let hs  = ScoreFunctions.humidityScore(w.avgHumidity)
        let sts = ScoreFunctions.soilTempScore(w.avgSoilTemp7d)

        let ww = weights.weather
        let rawWeather = ww.rain14d * rs + ww.rainTrigger * trs + ww.temperature * ts
        let humMult = weights.humidityMultiplierMin + (1.0 - weights.humidityMultiplierMin) * hs
        let weatherScore = rawWeather * humMult * sts

        let sqrtBase = base.squareRoot()
        let season = ScoreFunctions.seasonScore(dayOfYear: input.dayOfYear)
        let final_ = min(1.0, max(0.0, sqrtBase * weatherScore * season))

        return Breakdown(
            latitude: p.latitude, longitude: p.longitude,
            altitude: p.altitude, forestType: "\(p.forestType)", soilType: "\(p.soilType)", aspect: p.aspect,
            rain14d: w.rain14d, maxRain2d: w.maxRain2d,
            avgTemperature: w.avgTemperature, avgHumidity: w.avgHumidity, avgSoilTemp7d: w.avgSoilTemp7d,
            forestScore: fs, altitudeScore: als, soilScore: ss, aspectScore: asp, baseScore: base,
            rainScore: rs, rainTriggerScore: trs, tempScore: ts, humidityScore: hs, soilTempScore: sts,
            humidityMultiplier: humMult, rawWeatherScore: rawWeather, weatherScore: weatherScore,
            seasonMultiplier: season, sqrtBaseScore: sqrtBase, finalScore: final_
        )
    }
}
