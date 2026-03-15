import Foundation

struct ScoringEngine: Sendable {
    let weights: ScoringWeights

    struct Input: Sendable {
        let point: GridPoint
        let weather: WeatherData
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
        let als = ScoreFunctions.altitudeScore(input.point.altitude)
        let ss = ScoreFunctions.soilScore(input.point.soilType)
        let asp = ScoreFunctions.aspectScore(input.point.aspect)

        let bw = weights.base
        let baseScore = bw.forest * fs + bw.altitude * als + bw.soil * ss + bw.aspect * asp

        // Phenological weather score — fruiting conditions
        let rs = ScoreFunctions.rainScore(input.weather.rain14d)
        let ts = ScoreFunctions.tempScore(input.weather.avgTemperature)
        let hs = ScoreFunctions.humidityScore(input.weather.avgHumidity)

        let ww = weights.weather
        let rawWeather = ww.rain14d * rs + ww.temperature * ts
        let humidityMultiplier = weights.humidityMultiplierMin
            + (1.0 - weights.humidityMultiplierMin) * hs
        let weatherScore = rawWeather * humidityMultiplier

        let finalScore = min(1.0, max(0.0, baseScore * weatherScore))

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
