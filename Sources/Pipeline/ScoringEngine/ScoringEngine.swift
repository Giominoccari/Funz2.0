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

        // Base score gates: no habitat = no mushrooms, regardless of weather.
        // Direct multiplication: both habitat AND weather must be strong to score high.
        // The colormap uses absolute thresholds, so no sqrt inflation needed here.
        let product = baseScore * weatherScore
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
}
