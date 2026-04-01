import Testing
@testable import App

@Suite("ScoringEngine Tests")
struct ScoringEngineTests {

    // Use mid-summer dayOfYear for most tests (prime season, score=1.0)
    static let summerDay = 196 // July 15

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
        #expect(ScoreFunctions.soilScore(.siliceous) == 0.90)
        #expect(ScoreFunctions.soilScore(.calcareous) == 0.55)
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

    // MARK: - Rain Trigger

    @Test("rainTriggerScore no trigger event returns zero")
    func rainTriggerZero() {
        #expect(ScoreFunctions.rainTriggerScore(0) == 0.0)
        #expect(ScoreFunctions.rainTriggerScore(4) == 0.0)
    }

    @Test("rainTriggerScore optimal trigger returns 1.0")
    func rainTriggerOptimal() {
        #expect(ScoreFunctions.rainTriggerScore(25) == 1.0)
        #expect(ScoreFunctions.rainTriggerScore(40) == 1.0)
        #expect(ScoreFunctions.rainTriggerScore(50) == 1.0)
    }

    @Test("rainTriggerScore extreme event declines but floors at 0.4")
    func rainTriggerExtreme() {
        let score90 = ScoreFunctions.rainTriggerScore(90)
        #expect(score90 == 0.4)
    }

    // MARK: - Temperature

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

    // MARK: - Humidity

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

    // MARK: - Soil Temperature

    @Test("soilTempScore cold soil returns zero")
    func soilTempCold() {
        #expect(ScoreFunctions.soilTempScore(0) == 0.0)
        #expect(ScoreFunctions.soilTempScore(5) == 0.0)
    }

    @Test("soilTempScore optimal range returns 1.0")
    func soilTempOptimal() {
        #expect(ScoreFunctions.soilTempScore(12) == 1.0)
        #expect(ScoreFunctions.soilTempScore(16) == 1.0)
        #expect(ScoreFunctions.soilTempScore(22) == 1.0)
    }

    @Test("soilTempScore hot soil declines")
    func soilTempHot() {
        let score25 = ScoreFunctions.soilTempScore(25)
        #expect(score25 > 0.3 && score25 < 1.0)

        let score30 = ScoreFunctions.soilTempScore(30)
        #expect(score30 == 0.1)
    }

    // MARK: - Altitude (seasonal)

    @Test("altitudeScore below 50m returns 0.05")
    func altitudeScoreLowland() {
        #expect(ScoreFunctions.altitudeScore(30, dayOfYear: Self.summerDay) == 0.05)
    }

    @Test("altitudeScore summer optimal range returns 1.0")
    func altitudeScoreSummerOptimal() {
        // Summer (Jul): optimal 700-1600m
        #expect(ScoreFunctions.altitudeScore(800, dayOfYear: Self.summerDay) == 1.0)
        #expect(ScoreFunctions.altitudeScore(1200, dayOfYear: Self.summerDay) == 1.0)
        #expect(ScoreFunctions.altitudeScore(1600, dayOfYear: Self.summerDay) == 1.0)
    }

    @Test("altitudeScore spring favors lower elevations")
    func altitudeScoreSpring() {
        let springDay = 135 // May 15
        // 500m should be in optimal band in spring (300-1000m)
        #expect(ScoreFunctions.altitudeScore(500, dayOfYear: springDay) == 1.0)
        // 1400m should be declining in spring
        let score1400 = ScoreFunctions.altitudeScore(1400, dayOfYear: springDay)
        #expect(score1400 < 1.0)
    }

    @Test("altitudeScore high altitude declines")
    func altitudeScoreDecline() {
        let score2100 = ScoreFunctions.altitudeScore(2100, dayOfYear: Self.summerDay)
        #expect(score2100 > 0.05 && score2100 < 1.0)
    }

    // MARK: - Aspect

    @Test("aspectScore flat terrain returns 0.5")
    func aspectScoreFlat() {
        #expect(ScoreFunctions.aspectScore(0) == 0.5)
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

    // MARK: - Season

    @Test("seasonScore prime season returns 1.0")
    func seasonPrime() {
        #expect(ScoreFunctions.seasonScore(dayOfYear: 180) == 1.0) // late June
        #expect(ScoreFunctions.seasonScore(dayOfYear: 250) == 1.0) // early Sep
        #expect(ScoreFunctions.seasonScore(dayOfYear: 304) == 1.0) // end Oct
    }

    @Test("seasonScore deep winter returns 0.10")
    func seasonWinter() {
        #expect(ScoreFunctions.seasonScore(dayOfYear: 15) == 0.10) // January
        #expect(ScoreFunctions.seasonScore(dayOfYear: 350) == 0.10) // December
    }

    @Test("seasonScore spring ramps up")
    func seasonSpring() {
        let april = ScoreFunctions.seasonScore(dayOfYear: 105)
        let may = ScoreFunctions.seasonScore(dayOfYear: 140)
        #expect(april > 0.10 && april < 0.50)
        #expect(may > 0.50 && may < 1.0)
    }

    @Test("seasonScore late autumn declines")
    func seasonAutumn() {
        let earlyNov = ScoreFunctions.seasonScore(dayOfYear: 310)
        let lateNov = ScoreFunctions.seasonScore(dayOfYear: 330)
        #expect(earlyNov > lateNov)
        #expect(lateNov > 0.10)
    }

    // MARK: - ScoringEngine integration

    static let defaultWeights = ScoringWeights(
        base: ScoringWeights.BaseWeights(
            forest: 0.40, altitude: 0.25, soil: 0.20, aspect: 0.15
        ),
        weather: ScoringWeights.WeatherScoringWeights(
            rain14d: 0.40, rainTrigger: 0.20, temperature: 0.40
        ),
        humidityMultiplierMin: 0.15
    )

    @Test("Perfect conditions in summer yield high score")
    func perfectConditions() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .mixed, aspect: 360
        )
        let weather = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 80, avgSoilTemp7d: 15
        )
        let result = engine.score(.init(point: point, weather: weather, dayOfYear: Self.summerDay))
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
        let weather = WeatherData(
            rain14d: 0, maxRain2d: 0, avgTemperature: 2, avgHumidity: 10, avgSoilTemp7d: 3
        )
        let result = engine.score(.init(point: point, weather: weather, dayOfYear: Self.summerDay))
        #expect(result.score < 0.05)
    }

    @Test("Winter date drastically reduces score even with good conditions")
    func winterPenalty() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .mixed, aspect: 360
        )
        let weather = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 80, avgSoilTemp7d: 15
        )
        let summerResult = engine.score(.init(point: point, weather: weather, dayOfYear: Self.summerDay))
        let winterResult = engine.score(.init(point: point, weather: weather, dayOfYear: 15))
        #expect(winterResult.score < summerResult.score * 0.2)
        #expect(winterResult.score > 0.0) // never fully zero
    }

    @Test("Cold soil temperature kills weather score")
    func coldSoilGate() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .mixed, aspect: 360
        )
        let warmSoil = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 80, avgSoilTemp7d: 15
        )
        let coldSoil = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 80, avgSoilTemp7d: 4
        )
        let warmResult = engine.score(.init(point: point, weather: warmSoil, dayOfYear: Self.summerDay))
        let coldResult = engine.score(.init(point: point, weather: coldSoil, dayOfYear: Self.summerDay))
        #expect(coldResult.score < warmResult.score * 0.3)
    }

    @Test("Score is clamped between 0 and 1")
    func scoreClamped() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(
            latitude: 46.0, longitude: 11.3,
            altitude: 800, forestType: .mixed,
            soilType: .mixed, aspect: 360
        )
        let weather = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 100, avgSoilTemp7d: 15
        )
        let result = engine.score(.init(point: point, weather: weather, dayOfYear: Self.summerDay))
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
                weather: WeatherData(
                    rain14d: 60, maxRain2d: 25, avgTemperature: 16, avgHumidity: 75, avgSoilTemp7d: 14
                ),
                dayOfYear: Self.summerDay
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
        let wetWeather = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 90, avgSoilTemp7d: 15
        )
        let dryWeather = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 20, avgSoilTemp7d: 15
        )

        let wetResult = engine.score(.init(point: point, weather: wetWeather, dayOfYear: Self.summerDay))
        let dryResult = engine.score(.init(point: point, weather: dryWeather, dayOfYear: Self.summerDay))

        #expect(wetResult.score > dryResult.score)
    }

    @Test("Result contains correct coordinates")
    func resultCoordinates() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.123, longitude: 11.456, altitude: 500, forestType: .broadleaf, soilType: .mixed)
        let weather = WeatherData(
            rain14d: 60, maxRain2d: 25, avgTemperature: 16, avgHumidity: 70, avgSoilTemp7d: 14
        )
        let result = engine.score(.init(point: point, weather: weather, dayOfYear: Self.summerDay))
        #expect(result.latitude == 46.123)
        #expect(result.longitude == 11.456)
    }

    @Test("Result exposes baseScore and weatherScore")
    func resultExposesLayerScores() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 800, forestType: .mixed, soilType: .mixed, aspect: 360)
        let weather = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 80, avgSoilTemp7d: 15
        )
        let result = engine.score(.init(point: point, weather: weather, dayOfYear: Self.summerDay))
        #expect(result.baseScore > 0.0)
        #expect(result.weatherScore > 0.0)
        #expect(result.score > 0.0)
    }

    @Test("baseScore is independent of weather data")
    func baseScoreIndependent() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 800, forestType: .mixed, soilType: .mixed, aspect: 360)
        let weather1 = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 80, avgSoilTemp7d: 15
        )
        let weather2 = WeatherData(
            rain14d: 10, maxRain2d: 5, avgTemperature: 5, avgHumidity: 30, avgSoilTemp7d: 8
        )

        let result1 = engine.score(.init(point: point, weather: weather1, dayOfYear: Self.summerDay))
        let result2 = engine.score(.init(point: point, weather: weather2, dayOfYear: Self.summerDay))

        #expect(result1.baseScore == result2.baseScore)
    }

    @Test("weatherScore is independent of geo data")
    func weatherScoreIndependent() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point1 = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 800, forestType: .mixed, soilType: .mixed, aspect: 360)
        let point2 = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 200, forestType: .none, soilType: .other, aspect: 180)
        let weather = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 80, avgSoilTemp7d: 15
        )

        let result1 = engine.score(.init(point: point1, weather: weather, dayOfYear: Self.summerDay))
        let result2 = engine.score(.init(point: point2, weather: weather, dayOfYear: Self.summerDay))

        #expect(result1.weatherScore == result2.weatherScore)
    }

    @Test("Poor habitat yields low final score even with perfect weather")
    func poorHabitatYieldsLowScore() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 30, forestType: .none, soilType: .other, aspect: 180)
        let weather = WeatherData(
            rain14d: 60, maxRain2d: 30, avgTemperature: 16, avgHumidity: 80, avgSoilTemp7d: 15
        )
        let result = engine.score(.init(point: point, weather: weather, dayOfYear: Self.summerDay))
        #expect(result.score < 0.35)
        #expect(result.baseScore < 0.15)
    }

    @Test("Zero weather yields near-zero final score regardless of habitat")
    func zeroWeatherYieldsNearZero() {
        let engine = ScoringEngine(weights: ScoringEngineTests.defaultWeights)
        let point = GridPoint(latitude: 46.0, longitude: 11.3, altitude: 800, forestType: .mixed, soilType: .mixed, aspect: 360)
        let weather = WeatherData(
            rain14d: 0, maxRain2d: 0, avgTemperature: 2, avgHumidity: 0, avgSoilTemp7d: 3
        )
        let result = engine.score(.init(point: point, weather: weather, dayOfYear: Self.summerDay))
        #expect(result.score < 0.05)
    }

    // MARK: - WeatherData aggregation

    @Test("WeatherData aggregate computes maxRain2d correctly")
    func weatherAggregateMaxRain2d() {
        let observations = [
            DailyObservation(date: "2026-03-01", rainMm: 2, tempMeanC: 10, humidityPct: 60, soilTempC: 8),
            DailyObservation(date: "2026-03-02", rainMm: 15, tempMeanC: 10, humidityPct: 70, soilTempC: 8),
            DailyObservation(date: "2026-03-03", rainMm: 20, tempMeanC: 11, humidityPct: 75, soilTempC: 9),
            DailyObservation(date: "2026-03-04", rainMm: 5, tempMeanC: 12, humidityPct: 65, soilTempC: 9),
        ]
        let data = WeatherData.aggregate(from: observations)
        #expect(data.maxRain2d == 35) // day 2 + day 3: 15 + 20
        #expect(data.rain14d == 42) // sum of all
    }

    @Test("WeatherData aggregate computes avgSoilTemp7d from last 7 days")
    func weatherAggregateSoilTemp() {
        var observations: [DailyObservation] = []
        for i in 0..<14 {
            observations.append(DailyObservation(
                date: "2026-03-\(String(format: "%02d", i + 1))",
                rainMm: 3,
                tempMeanC: 10,
                humidityPct: 60,
                soilTempC: i < 7 ? 5.0 : 12.0 // first 7 days cold, last 7 warm
            ))
        }
        let data = WeatherData.aggregate(from: observations)
        #expect(abs(data.avgSoilTemp7d - 12.0) < 0.01)
    }

    // MARK: - PipelineRunner day-of-year extraction

    @Test("extractDayOfYear parses correctly")
    func extractDayOfYear() {
        #expect(PipelineRunner.extractDayOfYear(from: "2026-01-01") == 1)
        #expect(PipelineRunner.extractDayOfYear(from: "2026-07-15") == 196)
        #expect(PipelineRunner.extractDayOfYear(from: "2026-12-31") == 365)
    }

    @Test("extractDayOfYear invalid date returns mid-summer fallback")
    func extractDayOfYearFallback() {
        #expect(PipelineRunner.extractDayOfYear(from: "") == 166)
        #expect(PipelineRunner.extractDayOfYear(from: "invalid") == 166)
    }
}
