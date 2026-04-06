import Foundation
import Logging
import SQLKit

actor PipelineRunner {
    private let logger = Logger(label: "funghi.pipeline")

    private let config: PipelineConfig
    private let weatherClient: any WeatherClient
    private let geoEnrichmentClient: BatchGeoEnrichmentClient
    private let tileUploader: any TileUploader

    init(
        config: PipelineConfig,
        weatherClient: any WeatherClient,
        geoEnrichmentClient: BatchGeoEnrichmentClient,
        tileUploader: any TileUploader = MockTileUploader()
    ) {
        self.config = config
        self.weatherClient = weatherClient
        self.geoEnrichmentClient = geoEnrichmentClient
        self.tileUploader = tileUploader
    }

    func run(bbox: BoundingBox, date: String = "") async throws -> [ScoringEngine.Result] {
        let dayOfYear = Self.extractDayOfYear(from: date)
        let runStart = ContinuousClock.now

        // Phase 1 + 2: Generate grid and enrich with geo data.
        // Geo data is static (terrain doesn't change), so we cache the enriched
        // grid to disk and skip Phase 1+2 entirely on subsequent runs.
        let points: [GridPoint]
        let cacheFile = Self.geoCachePath(bbox: bbox, spacing: config.gridSpacingMeters)

        if let cached = Self.loadGeoCache(from: cacheFile, logger: logger) {
            points = cached
        } else {
            let phaseStart1 = ContinuousClock.now
            let gridGenerator = GridGenerator(spacingMeters: config.gridSpacingMeters)
            var generated = gridGenerator.generate(bbox: bbox)
            logger.info("Phase 1 — Grid generation complete", metadata: [
                "points": "\(generated.count)",
                "duration": "\(ContinuousClock.now - phaseStart1)"
            ])

            let phaseStart2 = ContinuousClock.now

            // Pre-filter to Italian territory before PostGIS raster queries.
            // Saves ~20-30% of geo enrichment calls that would otherwise hit
            // Croatian/Slovenian/Corsican forest areas inside the bbox.
            let beforeBoundary = generated.count
            do {
                generated = try await geoEnrichmentClient.filterToItaly(generated)
                logger.info("Phase 2 — Italy boundary filter applied", metadata: [
                    "before": "\(beforeBoundary)",
                    "after": "\(generated.count)",
                    "removed": "\(beforeBoundary - generated.count)"
                ])
            } catch {
                logger.warning("Italy boundary filter failed — proceeding without it", metadata: [
                    "error": "\(error)"
                ])
            }

            generated = await enrichWithGeoData(generated)
            let beforeFilter = generated.count
            generated = generated.filter { Self.isSuitableTerrain($0) }
            logger.info("Phase 2 — Geo data enrichment complete", metadata: [
                "pointsBefore": "\(beforeFilter)",
                "pointsAfter": "\(generated.count)",
                "filtered": "\(beforeFilter - generated.count)",
                "duration": "\(ContinuousClock.now - phaseStart2)"
            ])

            Self.saveGeoCache(generated, to: cacheFile, logger: logger)
            points = generated
        }

        // Phase 3: Fetch weather data
        let phaseStart3 = ContinuousClock.now
        let weatherMap = await fetchWeather(for: points, stepDeg: config.weather.resolvedWeatherStepHistorical)
        logger.info("Phase 3 — Weather fetch complete", metadata: [
            "points": "\(weatherMap.count)",
            "duration": "\(ContinuousClock.now - phaseStart3)"
        ])

        // Phase 4: Score
        let phaseStart4 = ContinuousClock.now
        let engine = ScoringEngine(weights: config.scoringWeights)
        let defaultWeather = WeatherData(
            rain14d: 0, maxRain2d: 0, avgTemperature: 0, avgHumidity: 0, avgSoilTemp7d: 0
        )
        let inputs = points.map { point in
            let key = "\(point.latitude),\(point.longitude)"
            let weather = weatherMap[key] ?? defaultWeather
            return ScoringEngine.Input(point: point, weather: weather, dayOfYear: dayOfYear)
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
        let results = try await run(bbox: bbox, date: date)

        // Phase 5: Tile generation + save score raster for dynamic tiles
        let phaseStart5 = ContinuousClock.now
        let tileGen = TileGenerator(
            tileZoomMin: config.tileZoomMin,
            tileZoomMax: config.tileZoomMax
        )
        let output = await tileGen.generateAll(results: results, bbox: bbox)

        // Save the raster (already built during tile gen) for dynamic tile endpoint
        let rasterPath = "Storage/tiles/\(date)/raster.bin"
        do {
            try output.raster.save(to: rasterPath)
            logger.info("Score raster saved", metadata: ["path": "\(rasterPath)"])
        } catch {
            logger.warning("Failed to save score raster", metadata: ["error": "\(error)"])
        }

        logger.info("Phase 5 — Tile generation complete", metadata: [
            "tiles": "\(output.tiles.count)",
            "duration": "\(ContinuousClock.now - phaseStart5)"
        ])

        // Phase 6: S3 upload
        let phaseStart6 = ContinuousClock.now
        try await tileUploader.upload(tiles: output.tiles, date: date)
        logger.info("Phase 6 — S3 upload complete", metadata: [
            "tiles": "\(output.tiles.count)",
            "duration": "\(ContinuousClock.now - phaseStart6)"
        ])

        logger.info("Full pipeline complete", metadata: [
            "totalPoints": "\(results.count)",
            "totalTiles": "\(output.tiles.count)",
            "date": "\(date)",
            "totalDuration": "\(ContinuousClock.now - fullStart)"
        ])
    }

    private func enrichWithGeoData(_ points: [GridPoint]) async -> [GridPoint] {
        let sqlBatchSize = config.resolvedGeoBatchSize
        let totalBatches = (points.count + sqlBatchSize - 1) / sqlBatchSize
        logger.info("Phase 2 — Geo enrichment starting", metadata: [
            "points": "\(points.count)",
            "batchSize": "\(sqlBatchSize)",
            "totalBatches": "\(totalBatches)"
        ])

        var enriched: [GridPoint] = []
        enriched.reserveCapacity(points.count)
        var failedCount = 0
        var processedCount = 0
        var batchIndex = 0
        let logEveryN = max(1, totalBatches / 10) // log ~10 times total

        for batchStart in stride(from: 0, to: points.count, by: sqlBatchSize) {
            let batchEnd = min(batchStart + sqlBatchSize, points.count)
            let batch = Array(points[batchStart..<batchEnd])
            let batchClock = ContinuousClock.now

            do {
                let results = try await geoEnrichmentClient.enrichBatch(batch)
                enriched.append(contentsOf: results)
            } catch {
                enriched.append(contentsOf: batch)
                failedCount += batch.count
                logger.warning("Geo enrichment batch failed", metadata: [
                    "batch": "\(batchIndex)/\(totalBatches)",
                    "error": "\(error)"
                ])
            }

            processedCount += batch.count
            batchIndex += 1
            let batchDuration = ContinuousClock.now - batchClock

            // Log first 3 batches individually (for calibration), then every ~10%
            if batchIndex <= 3 {
                logger.info("Phase 2 — Batch \(batchIndex)/\(totalBatches) complete", metadata: [
                    "duration": "\(batchDuration)",
                    "points": "\(batch.count)"
                ])
            } else if batchIndex % logEveryN == 0 {
                let pct = Int(Double(processedCount) / Double(points.count) * 100)
                logger.info("Phase 2 — Geo enrichment progress", metadata: [
                    "progress": "\(pct)%",
                    "batch": "\(batchIndex)/\(totalBatches)",
                    "lastBatchDuration": "\(batchDuration)"
                ])
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

    /// Weather varies slowly over space, so we sample a coarse grid and map each
    /// fine-grid point to its nearest coarse sample via IDW interpolation.
    /// - Parameter stepDeg: Coarse grid spacing in degrees.
    ///   Use `config.weather.resolvedWeatherStepHistorical` (~0.09° ≈ 10km) for historical maps.
    func fetchWeather(for points: [GridPoint], stepDeg: Double) async -> [String: WeatherData] {
        let defaultWeather = WeatherData(
            rain14d: 0, maxRain2d: 0, avgTemperature: 0, avgHumidity: 0, avgSoilTemp7d: 0
        )
        guard !points.isEmpty else { return [:] }

        let coarsePoints = buildCoarseGrid(from: points, stepDeg: stepDeg)

        logger.info("Weather coarse grid", metadata: [
            "coarsePoints": "\(coarsePoints.count)",
            "finePoints": "\(points.count)",
            "ratio": "\(String(format: "%.0f", Double(points.count) / Double(max(1, coarsePoints.count))))x reduction"
        ])

        let apiBatchSize = 50
        let totalApiBatches = (coarsePoints.count + apiBatchSize - 1) / apiBatchSize

        logger.info("Phase 3 — Weather fetch starting", metadata: [
            "coarsePoints": "\(coarsePoints.count)",
            "apiBatchSize": "\(apiBatchSize)",
            "totalApiCalls": "\(totalApiBatches)"
        ])

        var batchRanges: [(index: Int, start: Int, end: Int)] = []
        batchRanges.reserveCapacity(totalApiBatches)
        var bIdx = 0
        for batchStart in stride(from: 0, to: coarsePoints.count, by: apiBatchSize) {
            batchRanges.append((bIdx, batchStart, min(batchStart + apiBatchSize, coarsePoints.count)))
            bIdx += 1
        }

        let coarseSnapshot = coarsePoints

        let batchResults = await withTaskGroup(
            of: (index: Int, results: [(lat: Double, lon: Double, data: WeatherData)]).self,
            returning: [[(lat: Double, lon: Double, data: WeatherData)]].self
        ) { group in
            for range in batchRanges {
                group.addTask { [weatherClient, logger] in
                    let batch = Array(coarseSnapshot[range.start..<range.end])
                    let coords = batch.map { (latitude: $0.lat, longitude: $0.lon) }
                    do {
                        let weatherResults = try await weatherClient.fetchBatch(coordinates: coords)
                        let mapped = zip(batch, weatherResults).map { ($0.lat, $0.lon, $1) }
                        return (range.index, mapped)
                    } catch {
                        logger.warning("Weather batch fetch failed", metadata: [
                            "batchStart": "\(range.start)",
                            "batchSize": "\(batch.count)",
                            "error": "\(error)"
                        ])
                        let fallback = batch.map { ($0.lat, $0.lon, defaultWeather) }
                        return (range.index, fallback)
                    }
                }
            }

            var ordered = [[(lat: Double, lon: Double, data: WeatherData)]](
                repeating: [], count: totalApiBatches
            )
            var completed = 0
            let logInterval = max(1, totalApiBatches / 10)
            for await result in group {
                ordered[result.index] = result.results
                completed += 1
                if completed % logInterval == 0 {
                    let pct = Int(Double(completed) / Double(totalApiBatches) * 100)
                    logger.info("Phase 3 — Weather fetch progress", metadata: [
                        "progress": "\(pct)%",
                        "completed": "\(completed)/\(totalApiBatches)"
                    ])
                }
            }
            return ordered
        }

        let coarseWeather = batchResults.flatMap { $0 }
        let failedCount = coarseWeather.filter {
            $0.data.rain14d == 0 && $0.data.avgTemperature == 0 && $0.data.avgHumidity == 0
        }.count

        if failedCount > 0 {
            logger.warning("Weather fetch completed with failures", metadata: [
                "failed": "\(failedCount)",
                "total": "\(coarseSnapshot.count)"
            ])
        }

        return idwInterpolate(coarseWeather: coarseWeather, points: points, stepDeg: stepDeg)
    }

    /// Forecast pipeline: fetches 14-day blended weather (historical + forecast) for each
    /// of the next `days` days, scores, tiles, and uploads for each date.
    /// Tiles land at `forecast/YYYY-MM-DD/z/x/y.png`.
    func runForecast(
        bbox: BoundingBox,
        baseDate: String,
        days: Int = 5,
        openMeteoClient: OpenMeteoClient,
        db: any SQLDatabase
    ) async throws {
        let fullStart = ContinuousClock.now
        let defaultWeather = WeatherData(rain14d: 0, maxRain2d: 0, avgTemperature: 0, avgHumidity: 0, avgSoilTemp7d: 0)

        // Phase 1+2: Reuse geo cache (terrain is static)
        let points: [GridPoint]
        let cacheFile = Self.geoCachePath(bbox: bbox, spacing: config.gridSpacingMeters)
        if let cached = Self.loadGeoCache(from: cacheFile, logger: logger) {
            points = cached
        } else {
            logger.warning("Geo cache missing for forecast — run historical pipeline first")
            return
        }

        let stepDeg = config.weather.resolvedWeatherStepHistorical
        let coarsePoints = buildCoarseGrid(from: points, stepDeg: stepDeg)
        let coords = coarsePoints.map { (latitude: $0.lat, longitude: $0.lon) }

        logger.info("Forecast — coarse grid built", metadata: [
            "coarsePoints": "\(coarsePoints.count)",
            "finePoints": "\(points.count)"
        ])

        // Fetch historical observations from DB (last 13 days ending today)
        // Used to fill the look-back window for near-future forecast days.
        let histRepo = WeatherRepository(db: db)
        let histStart = Self.dateAddDays(baseDate, -13)
        let historicalByIndex: [Int: [DailyObservation]]
        do {
            historicalByIndex = try await histRepo.fetchExistingDaily(
                coordinates: coords, from: histStart, to: baseDate
            )
            logger.info("Forecast — historical data loaded from DB", metadata: [
                "from": "\(histStart)",
                "to": "\(baseDate)",
                "coordinatesWithData": "\(historicalByIndex.count)/\(coarsePoints.count)"
            ])
        } catch {
            logger.warning("Forecast — failed to load historical data, blend will use forecast-only", metadata: ["error": "\(error)"])
            historicalByIndex = [:]
        }

        // Fetch forecast observations: today (0) + days 1..days
        let forecastDaysToFetch = days + 1
        logger.info("Forecast — fetching Open-Meteo forecast", metadata: [
            "coordinates": "\(coarsePoints.count)",
            "forecastDays": "\(forecastDaysToFetch)"
        ])

        let apiBatchSize = 50
        var forecastByCoord = [[DailyObservation]](repeating: [], count: coarsePoints.count)

        let batchCount = (coarsePoints.count + apiBatchSize - 1) / apiBatchSize
        var batchRanges: [(index: Int, start: Int, end: Int)] = []
        for (i, batchStart) in stride(from: 0, to: coarsePoints.count, by: apiBatchSize).enumerated() {
            batchRanges.append((i, batchStart, min(batchStart + apiBatchSize, coarsePoints.count)))
        }
        let coordsSnapshot = coords
        let coarseSnapshot = coarsePoints

        let forecastBatchResults = await withTaskGroup(
            of: (index: Int, results: [(coordIdx: Int, obs: [DailyObservation])]).self,
            returning: [(index: Int, results: [(coordIdx: Int, obs: [DailyObservation])])].self
        ) { group in
            for range in batchRanges {
                group.addTask { [logger] in
                    let batchCoords = Array(coordsSnapshot[range.start..<range.end])
                    do {
                        let results = try await openMeteoClient.fetchForecastDailyBatch(
                            coordinates: batchCoords,
                            forecastDays: forecastDaysToFetch
                        )
                        let mapped = results.enumerated().map { (coordIdx: range.start + $0.offset, obs: $0.element) }
                        return (range.index, mapped)
                    } catch {
                        logger.warning("Forecast batch fetch failed", metadata: [
                            "batchStart": "\(range.start)",
                            "batchSize": "\(batchCoords.count)",
                            "error": "\(error)"
                        ])
                        let fallback = (range.start..<range.end).map { (coordIdx: $0, obs: [DailyObservation]()) }
                        return (range.index, fallback)
                    }
                }
            }

            var ordered = [(index: Int, results: [(coordIdx: Int, obs: [DailyObservation])])]()
            ordered.reserveCapacity(batchCount)
            for await result in group { ordered.append(result) }
            return ordered
        }

        for batch in forecastBatchResults {
            for entry in batch.results {
                forecastByCoord[entry.coordIdx] = entry.obs
            }
        }

        logger.info("Forecast — Open-Meteo fetch complete", metadata: [
            "fetched": "\(forecastByCoord.filter { !$0.isEmpty }.count)/\(coarsePoints.count)"
        ])

        // Generate one map per forecast day
        let tileGen = TileGenerator(tileZoomMin: config.tileZoomMin, tileZoomMax: config.tileZoomMax)
        let engine = ScoringEngine(weights: config.scoringWeights)

        for d in 1...days {
            let forecastDate = Self.dateAddDays(baseDate, d)
            let dayOfYear = Self.extractDayOfYear(from: forecastDate)
            let dayStart = ContinuousClock.now

            // Build blended WeatherData for each coarse point:
            //   historical: last (14-d) days from DB
            //   forecast:   days 1..d from Open-Meteo
            var coarseWeather: [(lat: Double, lon: Double, data: WeatherData)] = []
            coarseWeather.reserveCapacity(coarsePoints.count)

            for i in 0..<coarsePoints.count {
                let cp = coarseSnapshot[i]
                let histObs = historicalByIndex[i] ?? []
                let histWindow = Array(histObs.suffix(14 - d))

                let forecastObs = forecastByCoord[i]
                // forecastObs[0] = today, [1] = tomorrow, [d] = the target day
                let forecastWindow: [DailyObservation]
                if forecastObs.count > d {
                    forecastWindow = Array(forecastObs[1...d])
                } else {
                    forecastWindow = Array(forecastObs.dropFirst().prefix(d))
                }

                let combined = histWindow + forecastWindow
                coarseWeather.append((lat: cp.lat, lon: cp.lon, data: WeatherData.aggregate(from: combined)))
            }

            let weatherMap = idwInterpolate(coarseWeather: coarseWeather, points: points, stepDeg: stepDeg)

            let inputs = points.map { point in
                let key = "\(point.latitude),\(point.longitude)"
                return ScoringEngine.Input(point: point, weather: weatherMap[key] ?? defaultWeather, dayOfYear: dayOfYear)
            }
            let results = engine.scoreBatch(inputs)

            let output = await tileGen.generateAll(results: results, bbox: bbox)

            let rasterPath = "Storage/tiles/forecast/\(forecastDate)/raster.bin"
            do {
                try output.raster.save(to: rasterPath)
            } catch {
                logger.warning("Failed to save forecast raster", metadata: ["date": "\(forecastDate)", "error": "\(error)"])
            }

            try await tileUploader.upload(tiles: output.tiles, date: "forecast/\(forecastDate)")

            logger.info("Forecast day complete", metadata: [
                "date": "\(forecastDate)",
                "day": "\(d)/\(days)",
                "tiles": "\(output.tiles.count)",
                "duration": "\(ContinuousClock.now - dayStart)"
            ])
        }

        logger.info("Forecast pipeline complete", metadata: [
            "baseDate": "\(baseDate)",
            "days": "\(days)",
            "totalDuration": "\(ContinuousClock.now - fullStart)"
        ])
    }

    // MARK: - Shared weather helpers

    /// Builds a deduplicated coarse grid from fine-grid points by snapping to `stepDeg` cells.
    private func buildCoarseGrid(from points: [GridPoint], stepDeg: Double) -> [(lat: Double, lon: Double)] {
        var cells: Set<String> = []
        var coarse: [(lat: Double, lon: Double)] = []
        for p in points {
            let cellLat = (p.latitude  / stepDeg).rounded(.down) * stepDeg
            let cellLon = (p.longitude / stepDeg).rounded(.down) * stepDeg
            let key = "\(cellLat),\(cellLon)"
            if cells.insert(key).inserted {
                coarse.append((cellLat, cellLon))
            }
        }
        return coarse
    }

    /// IDW interpolation from coarse weather samples to fine-grid points.
    /// Uses spatial bucketing (3x3 cell search) for O(1) neighbor lookup.
    private func idwInterpolate(
        coarseWeather: [(lat: Double, lon: Double, data: WeatherData)],
        points: [GridPoint],
        stepDeg: Double
    ) -> [String: WeatherData] {
        let defaultWeather = WeatherData(rain14d: 0, maxRain2d: 0, avgTemperature: 0, avgHumidity: 0, avgSoilTemp7d: 0)
        let weatherCellSize = stepDeg * 1.1

        var weatherGrid: [Int: [(lat: Double, lon: Double, data: WeatherData)]] = [:]
        weatherGrid.reserveCapacity(coarseWeather.count)
        for cw in coarseWeather {
            let key = Int(floor(cw.lat / weatherCellSize)) * 100_000
                    + Int(floor(cw.lon / weatherCellSize))
            weatherGrid[key, default: []].append(cw)
        }

        var weatherMap: [String: WeatherData] = [:]
        weatherMap.reserveCapacity(points.count)
        var interpCount = 0
        let interpLogInterval = max(1, points.count / 10)

        for point in points {
            let key = "\(point.latitude),\(point.longitude)"
            let centerLatCell = Int(floor(point.latitude  / weatherCellSize))
            let centerLonCell = Int(floor(point.longitude / weatherCellSize))

            var weightedRain = 0.0, weightedMaxRain2d = 0.0
            var weightedTemp = 0.0, weightedHum = 0.0, weightedSoilTemp = 0.0
            var totalWeight = 0.0
            var exactMatch = false

            outer: for dLat in -1...1 {
                for dLon in -1...1 {
                    let cellKey = (centerLatCell + dLat) * 100_000 + (centerLonCell + dLon)
                    guard let cellPoints = weatherGrid[cellKey] else { continue }
                    for cw in cellPoints {
                        let dLatDiff = point.latitude  - cw.lat
                        let dLonDiff = point.longitude - cw.lon
                        let distSq = dLatDiff * dLatDiff + dLonDiff * dLonDiff

                        if distSq < 1e-12 {
                            weightedRain = cw.data.rain14d; weightedMaxRain2d = cw.data.maxRain2d
                            weightedTemp = cw.data.avgTemperature; weightedHum = cw.data.avgHumidity
                            weightedSoilTemp = cw.data.avgSoilTemp7d; totalWeight = 1.0; exactMatch = true
                            break outer
                        }

                        let weight = 1.0 / (distSq * distSq) // power=4 for smoother falloff
                        weightedRain += weight * cw.data.rain14d
                        weightedMaxRain2d += weight * cw.data.maxRain2d
                        weightedTemp += weight * cw.data.avgTemperature
                        weightedHum += weight * cw.data.avgHumidity
                        weightedSoilTemp += weight * cw.data.avgSoilTemp7d
                        totalWeight += weight
                    }
                }
            }

            if totalWeight > 0 {
                let w = exactMatch ? 1.0 : totalWeight
                weatherMap[key] = WeatherData(
                    rain14d: weightedRain / w,
                    maxRain2d: weightedMaxRain2d / w,
                    avgTemperature: weightedTemp / w,
                    avgHumidity: weightedHum / w,
                    avgSoilTemp7d: weightedSoilTemp / w
                )
            } else {
                weatherMap[key] = defaultWeather
            }

            interpCount += 1
            if interpCount % interpLogInterval == 0 {
                let pct = Int(Double(interpCount) / Double(points.count) * 100)
                logger.info("Phase 3 — Interpolation progress", metadata: [
                    "progress": "\(pct)%",
                    "processed": "\(interpCount)/\(points.count)"
                ])
            }
        }

        return weatherMap
    }

    /// Returns `dateString + days` as a "YYYY-MM-DD" string.
    static func dateAddDays(_ dateString: String, _ days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: dateString),
              let result = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date)
        else { return dateString }
        return formatter.string(from: result)
    }

    // MARK: - Geo cache (static terrain data)
    //
    // Binary format: 35 bytes per point
    //   lat(8B) + lon(8B) + altitude(8B) + aspect(8B) + forestType(1B) + soilType(1B) + corineCode(1B)
    //
    // Cache version: bump this constant whenever the set of filters changes
    // (e.g. adding Italy boundary filter) to force automatic cache regeneration.
    private static let cacheVersion = 2  // v2: added Italy boundary filter
    private static let cacheDir = ".cache"
    private static let recordSize = 35

    private static func geoCachePath(bbox: BoundingBox, spacing: Int) -> String {
        let key = "\(bbox.minLat)_\(bbox.maxLat)_\(bbox.minLon)_\(bbox.maxLon)_\(spacing)_v\(cacheVersion)"
        return "\(cacheDir)/geo_\(key).bin"
    }

    private static func loadGeoCache(from path: String, logger: Logger) -> [GridPoint]? {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else {
            logger.info("No geo cache found, will compute", metadata: ["path": "\(path)"])
            return nil
        }

        let count = data.count / recordSize
        guard data.count % recordSize == 0 else {
            logger.warning("Geo cache corrupted (bad size), will regenerate")
            return nil
        }
        // Valid cache with 0 points means all points were filtered out
        guard count > 0 else {
            logger.info("Geo cache loaded (empty — all points filtered)", metadata: ["file": "\(path)"])
            return []
        }

        var points: [GridPoint] = []
        points.reserveCapacity(count)

        data.withUnsafeBytes { buf in
            let ptr = buf.baseAddress!
            for i in 0..<count {
                let offset = i * recordSize
                let lat = ptr.loadUnaligned(fromByteOffset: offset, as: Double.self)
                let lon = ptr.loadUnaligned(fromByteOffset: offset + 8, as: Double.self)
                let alt = ptr.loadUnaligned(fromByteOffset: offset + 16, as: Double.self)
                let asp = ptr.loadUnaligned(fromByteOffset: offset + 24, as: Double.self)
                let ft = ptr.load(fromByteOffset: offset + 32, as: UInt8.self)
                let st = ptr.load(fromByteOffset: offset + 33, as: UInt8.self)
                let cc = ptr.load(fromByteOffset: offset + 34, as: UInt8.self)
                points.append(GridPoint(
                    latitude: lat, longitude: lon,
                    altitude: alt,
                    forestType: Self.forestFromByte(ft),
                    soilType: Self.soilFromByte(st),
                    aspect: asp,
                    corineCode: Int(cc)
                ))
            }
        }

        let sizeMB = String(format: "%.1f", Double(data.count) / 1_048_576.0)
        logger.info("Phase 1+2 — Loaded geo cache", metadata: [
            "points": "\(points.count)",
            "sizeMB": "\(sizeMB)",
            "file": "\(path)"
        ])
        return points
    }

    private static func saveGeoCache(_ points: [GridPoint], to path: String, logger: Logger) {
        do {
            try FileManager.default.createDirectory(
                atPath: cacheDir,
                withIntermediateDirectories: true
            )

            var data = Data(capacity: points.count * recordSize)
            for p in points {
                var lat = p.latitude
                var lon = p.longitude
                var alt = p.altitude
                var asp = p.aspect
                let ft = Self.forestToByte(p.forestType)
                let st = Self.soilToByte(p.soilType)
                let cc = UInt8(clamping: p.corineCode)
                withUnsafeBytes(of: &lat) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &lon) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &alt) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &asp) { data.append(contentsOf: $0) }
                data.append(ft)
                data.append(st)
                data.append(cc)
            }

            try data.write(to: URL(fileURLWithPath: path))
            let sizeMB = String(format: "%.1f", Double(data.count) / 1_048_576.0)
            logger.info("Geo cache saved", metadata: [
                "points": "\(points.count)",
                "sizeMB": "\(sizeMB)",
                "file": "\(path)"
            ])
        } catch {
            logger.warning("Failed to save geo cache", metadata: ["error": "\(error)"])
        }
    }

    private static func forestToByte(_ f: ForestType) -> UInt8 {
        switch f {
        case .broadleaf:  return 0
        case .coniferous: return 1
        case .mixed:      return 2
        case .none:       return 3
        }
    }

    private static func forestFromByte(_ b: UInt8) -> ForestType {
        switch b {
        case 0: return .broadleaf
        case 1: return .coniferous
        case 2: return .mixed
        default: return .none
        }
    }

    private static func soilToByte(_ s: SoilType) -> UInt8 {
        switch s {
        case .calcareous: return 0
        case .siliceous:  return 1
        case .mixed:      return 2
        case .other:      return 3
        }
    }

    private static func soilFromByte(_ b: UInt8) -> SoilType {
        switch b {
        case 0: return .calcareous
        case 1: return .siliceous
        case 2: return .mixed
        default: return .other
        }
    }

    /// Filter out grid points on unsuitable terrain.
    /// Two hard filters based on scientific literature for Boletus edulis complex:
    /// 1. CORINE land cover: only keep classes where ectomycorrhizal host trees
    ///    can exist (Porcini are obligately ectomycorrhizal — no host = no fungi)
    /// 2. Altitude: exclude points above treeline (>2300m) and sea level (≤0m)
    private static func isSuitableTerrain(_ point: GridPoint) -> Bool {
        guard point.altitude > 0, point.altitude <= 2300 else { return false }
        return GridPoint.suitableCORINECodes.contains(point.corineCode)
    }

    /// Extract day-of-year (1-366) from a "YYYY-MM-DD" date string.
    /// Falls back to June 15 (prime season) if parsing fails.
    static func extractDayOfYear(from dateString: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: dateString) else { return 166 }
        return Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: date) ?? 166
    }
}
