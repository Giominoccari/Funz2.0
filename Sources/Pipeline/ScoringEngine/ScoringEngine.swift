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
    }

    func score(_ input: Input) -> Result {
        let fs = ScoreFunctions.forestScore(input.point.forestType)
        let rs = ScoreFunctions.rainScore(input.weather.rain14d)
        let ts = ScoreFunctions.tempScore(input.weather.avgTemperature)
        let hs = ScoreFunctions.humidityScore(input.weather.avgHumidity)
        let als = ScoreFunctions.altitudeScore(input.point.altitude)
        let ss = ScoreFunctions.soilScore(input.point.soilType)

        let raw = weights.forest * fs
            + weights.rain14d * rs
            + weights.temperature * ts
            + weights.altitude * als
            + weights.soil * ss

        // Humidity is not in the base config weights (5 weights sum to 1.0)
        // but we use it as a multiplier: low humidity penalizes the score
        let humidityMultiplier = 0.5 + 0.5 * hs // range [0.5 .. 1.0]
        let finalScore = min(1.0, max(0.0, raw * humidityMultiplier))

        return Result(
            latitude: input.point.latitude,
            longitude: input.point.longitude,
            score: finalScore
        )
    }

    func scoreBatch(_ inputs: [Input]) -> [Result] {
        inputs.map { score($0) }
    }
}
