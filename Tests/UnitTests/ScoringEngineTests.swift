import Testing
@testable import App

@Suite("ScoringEngine Tests")
struct ScoringEngineTests {

    // MARK: - ScoreFunctions individual tests

    @Test("forestScore returns correct values for each type")
    func forestScore() {
        #expect(ScoreFunctions.forestScore(.mixed) == 1.0)
        #expect(ScoreFunctions.forestScore(.broadleaf) == 0.85)
        #expect(ScoreFunctions.forestScore(.coniferous) == 0.80)
        #expect(ScoreFunctions.forestScore(.none) == 0.0)
    }

    @Test("soilScore returns correct values for each type")
    func soilScore() {
        #expect(ScoreFunctions.soilScore(.mixed) == 1.0)
        #expect(ScoreFunctions.soilScore(.calcareous) == 0.85)
        #expect(ScoreFunctions.soilScore(.siliceous) == 0.70)
        #expect(ScoreFunctions.soilScore(.other) == 0.2)
    }

    @Test("rainScore zero rain returns zero")
    func rainScoreZero() {
        #expect(ScoreFunctions.rainScore(0) == 0.0)
        #expect(ScoreFunctions.rainScore(-5) == 0.0)
    }

    @Test("rainScore optimal range returns 1.0")
    func rainScoreOptimal() {
        #expect(ScoreFunctions.rainScore(50) == 1.0)
        #expect(ScoreFunctions.rainScore(70) == 1.0)
        #expect(ScoreFunctions.rainScore(90) == 1.0)
    }

    @Test("rainScore low rain returns partial score")
    func rainScoreLow() {
        let score10 = ScoreFunctions.rainScore(10)
        #expect(score10 > 0.0 && score10 < 0.3)

        let score35 = ScoreFunctions.rainScore(35)
        #expect(score35 > 0.5 && score35 < 1.0)
    }

    @Test("rainScore excessive rain decreases but floors at 0.1")
    func rainScoreExcessive() {
        let score110 = ScoreFunctions.rainScore(110)
        #expect(score110 > 0.5 && score110 < 1.0)

        let score200 = ScoreFunctions.rainScore(200)
        #expect(score200 == 0.1)
    }

    @Test("tempScore below 4°C returns zero")
    func tempScoreFreezing() {
        #expect(ScoreFunctions.tempScore(0) == 0.0)
        #expect(ScoreFunctions.tempScore(3) == 0.0)
    }

    @Test("tempScore optimal range 12-20°C returns 1.0")
    func tempScoreOptimal() {
        #expect(ScoreFunctions.tempScore(12) == 1.0)
        #expect(ScoreFunctions.tempScore(16) == 1.0)
        #expect(ScoreFunctions.tempScore(20) == 1.0)
    }

    @Test("tempScore hot returns zero")
    func tempScoreHot() {
        #expect(ScoreFunctions.tempScore(31) == 0.0)
        #expect(ScoreFunctions.tempScore(40) == 0.0)
    }

    @Test("tempScore autumn range 4-12°C gives partial score")
    func tempScoreAutumn() {
        let score6 = ScoreFunctions.tempScore(6)
        #expect(score6 > 0.0 && score6 < 0.7)

        let score10 = ScoreFunctions.tempScore(10)
        #expect(score10 > 0.7 && score10 < 1.0)
    }

    @Test("humidityScore low returns zero")
    func humidityScoreLow() {
        #expect(ScoreFunctions.humidityScore(0) == 0.0)
        #expect(ScoreFunctions.humidityScore(29) == 0.0)
    }

    @Test("humidityScore high returns 1.0")
    func humidityScoreHigh() {
        #expect(ScoreFunctions.humidityScore(70) == 1.0)
        #expect(ScoreFunctions.humidityScore(100) == 1.0)
    }

    @Test("humidityScore mid range returns partial")
    func humidityScoreMid() {
        let score50 = ScoreFunctions.humidityScore(50)
        #expect(score50 == 0.5)
    }

    @Test("altitudeScore below 50m returns 0.05")
    func altitudeScoreLowland() {
        #expect(ScoreFunctions.altitudeScore(30) == 0.05)
    }

    @Test("altitudeScore optimal range 400-1800m returns 1.0")
    func altitudeScoreOptimal() {
        #expect(ScoreFunctions.altitudeScore(400) == 1.0)
        #expect(ScoreFunctions.altitudeScore(800) == 1.0)
        #expect(ScoreFunctions.altitudeScore(1200) == 1.0)
        #expect(ScoreFunctions.altitudeScore(1800) == 1.0)
    }

    @Test("altitudeScore above 2400m returns 0.1")
    func altitudeScoreAlpine() {
        #expect(ScoreFunctions.altitudeScore(2500) == 0.1)
    }

    @Test("altitudeScore gradual decline 1800-2400")
    func altitudeScoreDecline() {
        let score2100 = ScoreFunctions.altitudeScore(2100)
        #expect(score2100 > 0.1 && score2100 < 1.0)
    }

    @Test("aspectScore flat terrain returns 0.7")
    func aspectScoreFlat() {
        #expect(ScoreFunctions.aspectScore(0) == 0.7)
    }

    @Test("aspectScore north-facing returns 1.0")
    func aspectScoreNorth() {
        let score = ScoreFunctions.aspectScore(360)
        #expect(abs(score - 1.0) < 0.01)
    }

    @Test("aspectScore south-facing returns ~0.30")
    func aspectScoreSouth() {
        let score = ScoreFunctions.aspectScore(180)
        #expect(abs(score - 0.30) < 0.01)
    }

    @Test("aspectScore east/west returns ~0.65")
    func aspectScoreEastWest() {
        let scoreE = ScoreFunctions.aspectScore(90)
        let scoreW = ScoreFunctions.aspectScore(270)
        #expect(abs(scoreE - 0.65) < 0.01)
        #expect(abs(scoreW - 0.65) < 0.01)
    }

    // MARK: - ScoringEngine integration

    static let defaultWeights = ScoringWeights(
        base: ScoringWeights.BaseWeights(
            forest: 0.40, altitude: 0.25, soil: 0.20, aspect: 0.15
        ),
        weather: ScoringWeights.WeatherScoringWeights(
            rain14d: 0.55, temperature: 0.45
        ),
        humidityMultiplierMin: 0.4
    )

    @Test("Perfect conditions yield high score")
    func perfectConditions() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .mixed, aspect: 360
        )
        let weather = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 80)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.score > 0.80)
    }

    @Test("Terrible conditions yield low score")
    func terribleConditions() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 30, forestType: .none,
            soilType: .other, aspect: 180
        )
        let weather = WeatherData(rain14d: 0, avgTemperature: 2, avgHumidity: 10)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.score < 0.05)
    }

    @Test("Score is clamped between 0 and 1")
    func scoreClamped() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .mixed, aspect: 360
        )
        let weather = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 100)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.score >= 0.0 && result.score <= 1.0)
    }

    @Test("scoreBatch processes multiple inputs")
    func scoreBatch() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let inputs = (0..<10).map { i in
            ScoringEngine.Input(
                point: GridPoint(
                    latitude: 46.0 + Double(i) * 0.01,
                    longitude: 11.3,
                    altitude: 600,
                    forestType: .mixed,
                    soilType: .mixed
                ),
                weather: WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 75)
            )
        }
        let results = engine.scoreBatch(inputs)
        #expect(results.count == 10)
        for result in results {
            #expect(result.score > 0.0 && result.score <= 1.0)
        }
    }

    @Test("Low humidity penalizes weather score via multiplier")
    func humidityMultiplier() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .mixed, aspect: 360
        )
        let wetWeather = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 90)
        let dryWeather = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 20)

        let wetResult = engine.score(.init(point: point, weather: wetWeather))
        let dryResult = engine.score(.init(point: point, weather: dryWeather))

        #expect(wetResult.score > dryResult.score)
    }

    @Test("Result contains correct coordinates")
    func resultCoordinates() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.123, longitude: 11.456, altitude: 500, forestType: .broadleaf, soilType: .mixed)
        let weather = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 70)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.latitude == 46.123)
        #expect(result.longitude == 11.456)
    }

    @Test("Result exposes baseScore and weatherScore")
    func resultExposesLayerScores() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 800, forestType: .mixed, soilType: .mixed, aspect: 360)
        let weather = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 80)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.baseScore > 0.0)
        #expect(result.weatherScore > 0.0)
        #expect(result.score > 0.0)
    }

    @Test("baseScore is independent of weather data")
    func baseScoreIndependent() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 800, forestType: .mixed, soilType: .mixed, aspect: 360)
        let weather1 = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 80)
        let weather2 = WeatherData(rain14d: 10, avgTemperature: 5, avgHumidity: 30)

        let result1 = engine.score(.init(point: point, weather: weather1))
        let result2 = engine.score(.init(point: point, weather: weather2))

        #expect(result1.baseScore == result2.baseScore)
    }

    @Test("weatherScore is independent of geo data")
    func weatherScoreIndependent() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point1 = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 800, forestType: .mixed, soilType: .mixed, aspect: 360)
        let point2 = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 200, forestType: .none, soilType: .other, aspect: 180)
        let weather = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 80)

        let result1 = engine.score(.init(point: point1, weather: weather))
        let result2 = engine.score(.init(point: point2, weather: weather))

        #expect(result1.weatherScore == result2.weatherScore)
    }

    @Test("Poor habitat yields low final score even with perfect weather")
    func poorHabitatYieldsLowScore() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        // No forest, low altitude, poor soil, south-facing → base ≈ 0.10
        let point = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 30, forestType: .none, soilType: .other, aspect: 180)
        let weather = WeatherData(rain14d: 60, avgTemperature: 16, avgHumidity: 80)
        let result = engine.score(.init(point: point, weather: weather))
        // sqrt(~0.10 * 1.0) ≈ 0.31 — well below "good" threshold of 0.5
        #expect(result.score < 0.35)
        #expect(result.baseScore < 0.15)
    }

    @Test("Zero weather yields near-zero final score regardless of habitat")
    func zeroWeatherYieldsNearZero() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 800, forestType: .mixed, soilType: .mixed, aspect: 360)
        let weather = WeatherData(rain14d: 0, avgTemperature: 2, avgHumidity: 0)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.score < 0.05)
    }
}
