import Foundation
import Logging

actor PipelineRunner {
    private let logger = Logger(label: "funghi.pipeline")

    private let config: PipelineConfig
    private let weatherClient: any WeatherClient
    private let forestClient: any ForestCoverageClient
    private let altitudeClient: any AltitudeClient

    init(
        config: PipelineConfig,
        weatherClient: any WeatherClient,
        forestClient: any ForestCoverageClient,
        altitudeClient: any AltitudeClient
    ) {
        self.config = config
        self.weatherClient = weatherClient
        self.forestClient = forestClient
        self.altitudeClient = altitudeClient
    }

    func run(bbox: BoundingBox) async throws -> [ScoringEngine.Result] {
        let runStart = ContinuousClock.now

        // Phase 1: Generate grid
        let phaseStart1 = ContinuousClock.now
        let gridGenerator = GridGenerator(spacingMeters: config.gridSpacingMeters)
        var points = gridGenerator.generate(bbox: bbox)
        logger.info("Phase 1 — Grid generation complete", metadata: [
            "points": "\(points.count)",
            "duration": "\(ContinuousClock.now - phaseStart1)"
        ])

        // Phase 2: Enrich with geo data (forest, altitude, soil, aspect)
        let phaseStart2 = ContinuousClock.now
        points = try await enrichWithGeoData(points)
        logger.info("Phase 2 — Geo data enrichment complete", metadata: [
            "points": "\(points.count)",
            "duration": "\(ContinuousClock.now - phaseStart2)"
        ])

        // Phase 3: Fetch weather data
        let phaseStart3 = ContinuousClock.now
        let weatherMap = try await fetchWeather(for: points)
        logger.info("Phase 3 — Weather fetch complete", metadata: [
            "points": "\(weatherMap.count)",
            "duration": "\(ContinuousClock.now - phaseStart3)"
        ])

        // Phase 4: Score
        let phaseStart4 = ContinuousClock.now
        let engine = ScoringEngine(weights: config.scoringWeights)
        let inputs = points.map { point in
            let key = "\(point.latitude),\(point.longitude)"
            let weather = weatherMap[key] ?? WeatherData(rain14d: 0, avgTemperature: 0, avgHumidity: 0)
            return ScoringEngine.Input(point: point, weather: weather)
        }

        let results = engine.scoreBatch(inputs)
        logger.info("Phase 4 — Scoring complete", metadata: [
            "results": "\(results.count)",
            "duration": "\(ContinuousClock.now - phaseStart4)"
        ])

        let avgScore = results.isEmpty ? 0 : results.map(\.score).reduce(0, +) / Double(results.count)
        logger.info("Pipeline run complete", metadata: [
            "totalPoints": "\(results.count)",
            "avgScore": "\(String(format: "%.3f", avgScore))",
            "totalDuration": "\(ContinuousClock.now - runStart)"
        ])

        return results
    }

    private func enrichWithGeoData(_ points: [GridPoint]) async throws -> [GridPoint] {
        let batchSize = config.batchSize
        var enriched: [GridPoint] = []
        enriched.reserveCapacity(points.count)

        for batchStart in stride(from: 0, to: points.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, points.count)
            let batch = points[batchStart..<batchEnd]

            let batchResults = try await withThrowingTaskGroup(of: GridPoint.self) { group in
                for point in batch {
                    group.addTask {
                        var p = point
                        p.altitude = try await self.altitudeClient.altitude(
                            latitude: point.latitude, longitude: point.longitude
                        )
                        p.forestType = try await self.forestClient.forestType(
                            latitude: point.latitude, longitude: point.longitude
                        )
                        p.soilType = try await self.forestClient.soilType(
                            latitude: point.latitude, longitude: point.longitude
                        )
                        p.aspect = try await self.altitudeClient.aspect(
                            latitude: point.latitude, longitude: point.longitude
                        )
                        return p
                    }
                }
                var results: [GridPoint] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }

            enriched.append(contentsOf: batchResults)
        }

        return enriched
    }

    private func fetchWeather(for points: [GridPoint]) async throws -> [String: WeatherData] {
        let batchSize = config.batchSize
        var weatherMap: [String: WeatherData] = [:]

        for batchStart in stride(from: 0, to: points.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, points.count)
            let batch = points[batchStart..<batchEnd]

            let batchResults = try await withThrowingTaskGroup(
                of: (String, WeatherData).self
            ) { group in
                for point in batch {
                    group.addTask {
                        let weather = try await self.weatherClient.fetch(
                            latitude: point.latitude, longitude: point.longitude
                        )
                        let key = "\(point.latitude),\(point.longitude)"
                        return (key, weather)
                    }
                }
                var results: [(String, WeatherData)] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }

            for (key, weather) in batchResults {
                weatherMap[key] = weather
            }
        }

        return weatherMap
    }
}
