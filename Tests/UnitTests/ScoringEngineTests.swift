import Testing
@testable import App

@Suite("ScoringEngine Tests")
struct ScoringEngineTests {

    // MARK: - ScoreFunctions individual tests

    @Test("forestScore returns correct values for each type")
    func forestScore() {
        #expect(ScoreFunctions.forestScore(.mixed) == 1.0)
        #expect(ScoreFunctions.forestScore(.broadleaf) == 0.8)
        #expect(ScoreFunctions.forestScore(.coniferous) == 0.6)
        #expect(ScoreFunctions.forestScore(.none) == 0.0)
    }

    @Test("soilScore returns correct values for each type")
    func soilScore() {
        #expect(ScoreFunctions.soilScore(.calcareous) == 1.0)
        #expect(ScoreFunctions.soilScore(.mixed) == 0.8)
        #expect(ScoreFunctions.soilScore(.siliceous) == 0.5)
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
        #expect(ScoreFunctions.rainScore(40) == 1.0)
        #expect(ScoreFunctions.rainScore(80) == 1.0)
    }

    @Test("rainScore low rain returns partial score")
    func rainScoreLow() {
        let score10 = ScoreFunctions.rainScore(10)
        #expect(score10 > 0.0 && score10 < 0.5)

        let score30 = ScoreFunctions.rainScore(30)
        #expect(score30 > 0.5 && score30 < 1.0)
    }

    @Test("rainScore excessive rain decreases score")
    func rainScoreExcessive() {
        let score100 = ScoreFunctions.rainScore(100)
        #expect(score100 > 0.0 && score100 < 1.0)

        let score200 = ScoreFunctions.rainScore(200)
        #expect(score200 == 0.0)
    }

    @Test("tempScore freezing returns zero")
    func tempScoreFreezing() {
        #expect(ScoreFunctions.tempScore(0) == 0.0)
        #expect(ScoreFunctions.tempScore(4) == 0.0)
    }

    @Test("tempScore optimal range returns 1.0")
    func tempScoreOptimal() {
        #expect(ScoreFunctions.tempScore(15) == 1.0)
        #expect(ScoreFunctions.tempScore(18) == 1.0)
        #expect(ScoreFunctions.tempScore(22) == 1.0)
    }

    @Test("tempScore hot returns zero")
    func tempScoreHot() {
        #expect(ScoreFunctions.tempScore(31) == 0.0)
        #expect(ScoreFunctions.tempScore(40) == 0.0)
    }

    @Test("tempScore gradual increase 5-15")
    func tempScoreGradual() {
        let score10 = ScoreFunctions.tempScore(10)
        #expect(score10 == 0.5)
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

    @Test("altitudeScore below 100m returns 0.1")
    func altitudeScoreLowland() {
        #expect(ScoreFunctions.altitudeScore(50) == 0.1)
    }

    @Test("altitudeScore optimal range returns 1.0")
    func altitudeScoreOptimal() {
        #expect(ScoreFunctions.altitudeScore(400) == 1.0)
        #expect(ScoreFunctions.altitudeScore(800) == 1.0)
        #expect(ScoreFunctions.altitudeScore(1200) == 1.0)
    }

    @Test("altitudeScore above 2000m returns 0")
    func altitudeScoreAlpine() {
        #expect(ScoreFunctions.altitudeScore(2100) == 0.0)
    }

    @Test("altitudeScore gradual decline 1200-2000")
    func altitudeScoreDecline() {
        let score1600 = ScoreFunctions.altitudeScore(1600)
        #expect(score1600 == 0.5)
    }

    // MARK: - ScoringEngine integration

    static let defaultWeights = ScoringWeights(
        forest: 0.30, rain14d: 0.25, temperature: 0.20,
        altitude: 0.15, soil: 0.10
    )

    @Test("Perfect conditions yield high score")
    func perfectConditions() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .calcareous, aspect: 180
        )
        let weather = WeatherData(rain14d: 60, avgTemperature: 18, avgHumidity: 80)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.score > 0.85)
    }

    @Test("Terrible conditions yield low score")
    func terribleConditions() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 50, forestType: .none,
            soilType: .other, aspect: 0
        )
        let weather = WeatherData(rain14d: 0, avgTemperature: 2, avgHumidity: 10)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.score < 0.1)
    }

    @Test("Score is clamped between 0 and 1")
    func scoreClamped() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .calcareous, aspect: 180
        )
        let weather = WeatherData(rain14d: 60, avgTemperature: 18, avgHumidity: 100)
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
                    soilType: .calcareous
                ),
                weather: WeatherData(rain14d: 50, avgTemperature: 18, avgHumidity: 75)
            )
        }
        let results = engine.scoreBatch(inputs)
        #expect(results.count == 10)
        for result in results {
            #expect(result.score > 0.0 && result.score <= 1.0)
        }
    }

    @Test("Low humidity penalizes score via multiplier")
    func humidityMultiplier() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .calcareous, aspect: 180
        )
        let wetWeather = WeatherData(rain14d: 60, avgTemperature: 18, avgHumidity: 90)
        let dryWeather = WeatherData(rain14d: 60, avgTemperature: 18, avgHumidity: 20)

        let wetResult = engine.score(.init(point: point, weather: wetWeather))
        let dryResult = engine.score(.init(point: point, weather: dryWeather))

        #expect(wetResult.score > dryResult.score)
    }

    @Test("Result contains correct coordinates")
    func resultCoordinates() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.123, longitude: 11.456, altitude: 500, forestType: .broadleaf, soilType: .mixed)
        let weather = WeatherData(rain14d: 40, avgTemperature: 18, avgHumidity: 70)
        let result = engine.score(.init(point: point, weather: weather))
        #expect(result.latitude == 46.123)
        #expect(result.longitude == 11.456)
    }
}
