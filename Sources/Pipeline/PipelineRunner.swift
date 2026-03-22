import Foundation
import Logging

actor PipelineRunner {
    private let logger = Logger(label: "funghi.pipeline")

    private let config: PipelineConfig
    private let weatherClient: any WeatherClient
    private let forestClient: any ForestCoverageClient
    private let altitudeClient: any AltitudeClient
    private let tileUploader: any TileUploader
    private let dbSemaphore: AsyncSemaphore
    private let weatherSemaphore: AsyncSemaphore

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
        self.dbSemaphore = AsyncSemaphore(value: 20)
        self.weatherSemaphore = AsyncSemaphore(value: 20)
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

        let count = Double(results.count)
        let avgScore = results.isEmpty ? 0 : results.map(\.score).reduce(0, +) / count
        let avgBase = results.isEmpty ? 0 : results.map(\.baseScore).reduce(0, +) / count
        let avgWeather = results.isEmpty ? 0 : results.map(\.weatherScore).reduce(0, +) / count
        logger.info("Scoring complete", metadata: [
            "totalPoints": "\(results.count)",
            "avgScore": "\(String(format: "%.3f", avgScore))",
            "avgBaseScore": "\(String(format: "%.3f", avgBase))",
            "avgWeatherScore": "\(String(format: "%.3f", avgWeather))",
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
                        await self.dbSemaphore.wait()
                        defer { Task { await self.dbSemaphore.signal() } }
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

    /// Weather varies slowly over space (~10km resolution is sufficient).
    /// Instead of fetching 24K+ points, we sample a coarse grid and map each
    /// fine-grid point to its nearest coarse sample.
    private func fetchWeather(for points: [GridPoint]) async -> [String: WeatherData] {
        let defaultWeather = WeatherData(rain14d: 0, avgTemperature: 0, avgHumidity: 0)
        guard let first = points.first else { return [:] }

        // Determine bbox from points
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude)
            maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude)
            maxLon = max(maxLon, p.longitude)
        }

        // Generate coarse weather grid (~10km spacing ≈ 0.09° latitude)
        let weatherStepDeg = 0.09
        var coarsePoints: [(lat: Double, lon: Double)] = []
        var lat = minLat
        while lat <= maxLat + weatherStepDeg {
            var lon = minLon
            while lon <= maxLon + weatherStepDeg {
                coarsePoints.append((lat, lon))
                lon += weatherStepDeg
            }
            lat += weatherStepDeg
        }

        logger.info("Weather coarse grid", metadata: [
            "coarsePoints": "\(coarsePoints.count)",
            "finePoints": "\(points.count)",
            "ratio": "\(String(format: "%.0f", Double(points.count) / Double(max(1, coarsePoints.count))))x reduction"
        ])

        // Fetch weather for coarse grid points
        var coarseWeather: [(lat: Double, lon: Double, data: WeatherData)] = []
        var failedCount = 0

        for batchStart in stride(from: 0, to: coarsePoints.count, by: config.batchSize) {
            let batchEnd = min(batchStart + config.batchSize, coarsePoints.count)
            let batch = coarsePoints[batchStart..<batchEnd]

            let batchResults = await withTaskGroup(
                of: (Double, Double, WeatherData?, Error?).self
            ) { group in
                for cp in batch {
                    group.addTask {
                        await self.weatherSemaphore.wait()
                        defer { Task { await self.weatherSemaphore.signal() } }
                        do {
                            let weather = try await self.weatherClient.fetch(
                                latitude: cp.lat, longitude: cp.lon
                            )
                            return (cp.lat, cp.lon, weather, nil)
                        } catch {
                            return (cp.lat, cp.lon, nil, error)
                        }
                    }
                }
                var results: [(Double, Double, WeatherData?, Error?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            for (clat, clon, weather, error) in batchResults {
                if let weather {
                    coarseWeather.append((clat, clon, weather))
                } else {
                    failedCount += 1
                    coarseWeather.append((clat, clon, defaultWeather))
                    if let error {
                        logger.warning("Weather fetch failed", metadata: [
                            "lat": "\(clat)", "lon": "\(clon)",
                            "error": "\(error)"
                        ])
                    }
                }
            }
        }

        if failedCount > 0 {
            logger.warning("Weather fetch completed with failures", metadata: [
                "failed": "\(failedCount)",
                "total": "\(coarsePoints.count)"
            ])
        }

        // IDW-interpolate weather from coarse grid to each fine-grid point
        // so transitions are smooth instead of blocky nearest-neighbor jumps.
        var weatherMap: [String: WeatherData] = [:]
        weatherMap.reserveCapacity(points.count)

        for point in points {
            let key = "\(point.latitude),\(point.longitude)"

            var weightedRain = 0.0
            var weightedTemp = 0.0
            var weightedHum = 0.0
            var totalWeight = 0.0

            for cw in coarseWeather {
                let dLat = point.latitude - cw.lat
                let dLon = point.longitude - cw.lon
                let distSq = dLat * dLat + dLon * dLon

                if distSq < 1e-12 {
                    // Exactly on a coarse point
                    weightedRain = cw.data.rain14d
                    weightedTemp = cw.data.avgTemperature
                    weightedHum = cw.data.avgHumidity
                    totalWeight = 1.0
                    break
                }

                let weight = 1.0 / (distSq * distSq) // power=4 for smoother falloff
                weightedRain += weight * cw.data.rain14d
                weightedTemp += weight * cw.data.avgTemperature
                weightedHum += weight * cw.data.avgHumidity
                totalWeight += weight
            }

            if totalWeight > 0 {
                weatherMap[key] = WeatherData(
                    rain14d: weightedRain / totalWeight,
                    avgTemperature: weightedTemp / totalWeight,
                    avgHumidity: weightedHum / totalWeight
                )
            } else {
                weatherMap[key] = defaultWeather
            }
        }

        return weatherMap
    }
}
