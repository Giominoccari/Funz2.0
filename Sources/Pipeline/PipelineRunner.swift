import Foundation
import Logging

actor PipelineRunner {
    private let logger = Logger(label: "funghi.pipeline")

    private let config: PipelineConfig
    private let weatherClient: any WeatherClient
    private let forestClient: any ForestCoverageClient
    private let altitudeClient: any AltitudeClient
    private let tileUploader: any TileUploader

    init(
        config: PipelineConfig,
        weatherClient: any WeatherClient,
        forestClient: any ForestCoverageClient,
        altitudeClient: any AltitudeClient,
        tileUploader: any TileUploader = MockTileUploader()
    ) {
        self.config = config
        self.weatherClient = weatherClient
        self.forestClient = forestClient
        self.altitudeClient = altitudeClient
        self.tileUploader = tileUploader
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
        points = await enrichWithGeoData(points)
        logger.info("Phase 2 — Geo data enrichment complete", metadata: [
            "points": "\(points.count)",
            "duration": "\(ContinuousClock.now - phaseStart2)"
        ])

        // Phase 3: Fetch weather data
        let phaseStart3 = ContinuousClock.now
        let weatherMap = await fetchWeather(for: points)
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
        logger.info("Scoring complete", metadata: [
            "totalPoints": "\(results.count)",
            "avgScore": "\(String(format: "%.3f", avgScore))",
            "totalDuration": "\(ContinuousClock.now - runStart)"
        ])

        return results
    }

    /// Full pipeline: score → generate tiles → upload to S3.
    func runFull(bbox: BoundingBox, date: String) async throws {
        let fullStart = ContinuousClock.now

        // Phases 1-4: Scoring
        let results = try await run(bbox: bbox)

        // Phase 5: Tile generation
        let phaseStart5 = ContinuousClock.now
        let tileGen = TileGenerator(
            tileZoomMin: config.tileZoomMin,
            tileZoomMax: config.tileZoomMax
        )
        let tiles = tileGen.generateAll(results: results, bbox: bbox)
        logger.info("Phase 5 — Tile generation complete", metadata: [
            "tiles": "\(tiles.count)",
            "duration": "\(ContinuousClock.now - phaseStart5)"
        ])

        // Phase 6: S3 upload
        let phaseStart6 = ContinuousClock.now
        try await tileUploader.upload(tiles: tiles, date: date)
        logger.info("Phase 6 — S3 upload complete", metadata: [
            "tiles": "\(tiles.count)",
            "duration": "\(ContinuousClock.now - phaseStart6)"
        ])

        logger.info("Full pipeline complete", metadata: [
            "totalPoints": "\(results.count)",
            "totalTiles": "\(tiles.count)",
            "date": "\(date)",
            "totalDuration": "\(ContinuousClock.now - fullStart)"
        ])
    }

    private func enrichWithGeoData(_ points: [GridPoint]) async -> [GridPoint] {
        let batchSize = config.batchSize
        var enriched: [GridPoint] = []
        enriched.reserveCapacity(points.count)
        var failedCount = 0

        for batchStart in stride(from: 0, to: points.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, points.count)
            let batch = points[batchStart..<batchEnd]

            let batchResults = await withTaskGroup(
                of: (GridPoint, Error?).self
            ) { group in
                for point in batch {
                    group.addTask {
                        do {
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
                            return (p, nil)
                        } catch {
                            return (point, error)
                        }
                    }
                }
                var results: [(GridPoint, Error?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            for (point, error) in batchResults {
                enriched.append(point)
                if let error {
                    failedCount += 1
                    logger.warning("Geo enrichment failed for point", metadata: [
                        "lat": "\(point.latitude)",
                        "lon": "\(point.longitude)",
                        "error": "\(error)"
                    ])
                }
            }
        }

        if failedCount > 0 {
            logger.warning("Geo enrichment completed with failures", metadata: [
                "failed": "\(failedCount)",
                "total": "\(points.count)"
            ])
        }

        return enriched
    }

    private func fetchWeather(for points: [GridPoint]) async -> [String: WeatherData] {
        let batchSize = config.batchSize
        var weatherMap: [String: WeatherData] = [:]
        var failedCount = 0

        for batchStart in stride(from: 0, to: points.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, points.count)
            let batch = points[batchStart..<batchEnd]

            let batchResults = await withTaskGroup(
                of: (String, WeatherData?, Error?).self
            ) { group in
                for point in batch {
                    group.addTask {
                        let key = "\(point.latitude),\(point.longitude)"
                        do {
                            let weather = try await self.weatherClient.fetch(
                                latitude: point.latitude, longitude: point.longitude
                            )
                            return (key, weather, nil)
                        } catch {
                            return (key, nil, error)
                        }
                    }
                }
                var results: [(String, WeatherData?, Error?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            for (key, weather, error) in batchResults {
                if let weather {
                    weatherMap[key] = weather
                } else {
                    failedCount += 1
                    weatherMap[key] = WeatherData(rain14d: 0, avgTemperature: 0, avgHumidity: 0)
                    if let error {
                        logger.warning("Weather fetch failed for point", metadata: [
                            "key": "\(key)",
                            "error": "\(error)"
                        ])
                    }
                }
            }
        }

        if failedCount > 0 {
            logger.warning("Weather fetch completed with failures", metadata: [
                "failed": "\(failedCount)",
                "total": "\(points.count)"
            ])
        }

        return weatherMap
    }
}
