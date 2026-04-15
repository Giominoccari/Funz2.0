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

        logScoringDiagnostics(engine: engine, inputs: inputs, results: results, date: date, dayOfYear: dayOfYear)

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

        // Save the raster (already built during tile gen) for dynamic tile endpoint.
        // Evict the in-memory cache entry for this date so subsequent dynamic tile requests
        // load from the freshly written file rather than a stale in-memory copy.
        let rasterPath = "Storage/tiles/\(date)/raster.bin"
        do {
            try output.raster.save(to: rasterPath)
            await RasterCache.shared.evict(date: date)
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

    // MARK: - Scoring diagnostics

    /// Logs a detailed scoring breakdown after every pipeline run.
    ///
    /// Emits three groups of log lines:
    ///   1. Weather variable statistics — reveals zero-data points and distribution shape.
    ///   2. Score component distributions — pinpoints which function is suppressing scores.
    ///   3. Representative point breakdowns — top, mid, and tail scorers with full formula trace.
    private func logScoringDiagnostics(
        engine: ScoringEngine,
        inputs: [ScoringEngine.Input],
        results: [ScoringEngine.Result],
        date: String,
        dayOfYear: Int
    ) {
        guard !inputs.isEmpty else { return }

        let n = inputs.count

        // ── 1. Weather data statistics ────────────────────────────────────────────────
        let weathers = inputs.map(\.weather)
        let zeroWeather = weathers.filter {
            $0.rain14d == 0 && $0.avgTemperature == 0 && $0.avgHumidity == 0
        }.count

        func stats(_ values: [Double]) -> (min: Double, avg: Double, max: Double) {
            let mn = values.min() ?? 0
            let mx = values.max() ?? 0
            let av = values.reduce(0, +) / Double(max(1, values.count))
            return (mn, av, mx)
        }

        let rainStats    = stats(weathers.map(\.rain14d))
        let rain2dStats  = stats(weathers.map(\.maxRain2d))
        let tempStats    = stats(weathers.map(\.avgTemperature))
        let humStats     = stats(weathers.map(\.avgHumidity))
        let soilTStats   = stats(weathers.map(\.avgSoilTemp7d))

        let weatherMeta: Logger.Metadata = [
            "date": "\(date)",
            "zeroWeatherPoints": "\(zeroWeather)/\(n)",
            "rain14d_mm":    "min=\(fmt(rainStats.min))  avg=\(fmt(rainStats.avg))  max=\(fmt(rainStats.max))",
            "maxRain2d_mm":  "min=\(fmt(rain2dStats.min)) avg=\(fmt(rain2dStats.avg)) max=\(fmt(rain2dStats.max))",
            "avgTemp_C":     "min=\(fmt(tempStats.min))  avg=\(fmt(tempStats.avg))  max=\(fmt(tempStats.max))",
            "avgHumidity_%": "min=\(fmt(humStats.min))  avg=\(fmt(humStats.avg))  max=\(fmt(humStats.max))",
            "avgSoilTemp_C": "min=\(fmt(soilTStats.min)) avg=\(fmt(soilTStats.avg)) max=\(fmt(soilTStats.max))"
        ]
        logger.info("Scoring diag — weather inputs", metadata: weatherMeta)

        // ── 2. Score component distributions (sample all points) ─────────────────────
        // Compute each ScoreFunction output across all points to find bottlenecks.
        var sumFS = 0.0, sumALS = 0.0, sumSS = 0.0, sumASP = 0.0
        var sumRS = 0.0, sumTRS = 0.0, sumTS = 0.0, sumHS = 0.0, sumSTS = 0.0
        let sampleSeason = ScoreFunctions.seasonScore(dayOfYear: dayOfYear)
        for inp in inputs {
            sumFS  += ScoreFunctions.forestScore(inp.point.forestType)
            sumALS += ScoreFunctions.altitudeScore(inp.point.altitude, dayOfYear: dayOfYear)
            sumSS  += ScoreFunctions.soilScore(inp.point.soilType)
            sumASP += ScoreFunctions.aspectScore(inp.point.aspect)
            sumRS  += ScoreFunctions.rainScore(inp.weather.rain14d)
            sumTRS += ScoreFunctions.rainTriggerScore(inp.weather.maxRain2d)
            sumTS  += ScoreFunctions.tempScore(inp.weather.avgTemperature)
            sumHS  += ScoreFunctions.humidityScore(inp.weather.avgHumidity)
            sumSTS += ScoreFunctions.soilTempScore(inp.weather.avgSoilTemp7d)
        }
        let d = Double(n)

        let componentMeta: Logger.Metadata = [
            "date": "\(date)",
            "dayOfYear": "\(dayOfYear)",
            "seasonMultiplier": "\(fmt(sampleSeason))",
            "forest_avg":        "\(fmt(sumFS / d))",
            "altitude_avg":      "\(fmt(sumALS / d))",
            "soil_avg":          "\(fmt(sumSS / d))",
            "aspect_avg":        "\(fmt(sumASP / d))",
            "rainScore_avg":     "\(fmt(sumRS / d))",
            "rainTrigger_avg":   "\(fmt(sumTRS / d))",
            "tempScore_avg":     "\(fmt(sumTS / d))",
            "humidityScore_avg": "\(fmt(sumHS / d))",
            "soilTempScore_avg": "\(fmt(sumSTS / d))"
        ]
        logger.info("Scoring diag — component averages", metadata: componentMeta)

        // ── 3. Final score histogram ──────────────────────────────────────────────────
        var buckets = [Int](repeating: 0, count: 10)
        for r in results {
            let b = min(9, Int(r.score * 10))
            buckets[b] += 1
        }
        let histStr = (0..<10).map { i in
            "\(i*10)-\(i*10+10)%: \(buckets[i])"
        }.joined(separator: ", ")
        logger.info("Scoring diag — score histogram", metadata: [
            "date": "\(date)",
            "histogram": "\(histStr)"
        ])

        // ── 4. Representative point breakdowns ───────────────────────────────────────
        // Pick top 5, 5 from middle, 5 from bottom (non-zero) by final score.
        let indexed = results.enumerated().map { ($0.offset, $0.element.score) }
        let sorted = indexed.sorted { $0.1 > $1.1 }

        let nonZero = sorted.filter { $0.1 > 0 }
        var sampleIndices: [Int] = []
        sampleIndices += sorted.prefix(5).map(\.0)                          // top 5
        if nonZero.count >= 10 {
            let midStart = nonZero.count / 2 - 2
            sampleIndices += nonZero[max(0,midStart)..<min(nonZero.count, midStart+5)].map(\.0) // mid 5
        }
        sampleIndices += nonZero.suffix(5).map(\.0)                         // bottom non-zero 5

        for (rank, idx) in sampleIndices.enumerated() {
            guard idx < inputs.count else { continue }
            let b = engine.diagnose(inputs[idx])
            let ptMeta: Logger.Metadata = [
                "rank": "\(rank+1)/\(sampleIndices.count)",
                "lat": "\(fmt(b.latitude))", "lon": "\(fmt(b.longitude))",
                "alt_m": "\(fmt(b.altitude))",
                "forest": "\(b.forestType)", "soil": "\(b.soilType)", "aspect": "\(fmt(b.aspect))",
                "rain14d": "\(fmt(b.rain14d))", "maxRain2d": "\(fmt(b.maxRain2d))",
                "temp": "\(fmt(b.avgTemperature))", "hum%": "\(fmt(b.avgHumidity))", "soilT": "\(fmt(b.avgSoilTemp7d))",
                "fS": "\(fmt(b.forestScore))", "aS": "\(fmt(b.altitudeScore))",
                "sS": "\(fmt(b.soilScore))", "aspS": "\(fmt(b.aspectScore))",
                "base": "\(fmt(b.baseScore))", "sqrtBase": "\(fmt(b.sqrtBaseScore))",
                "rS": "\(fmt(b.rainScore))", "trS": "\(fmt(b.rainTriggerScore))",
                "tS": "\(fmt(b.tempScore))", "hMult": "\(fmt(b.humidityMultiplier))",
                "sTMult": "\(fmt(b.soilTempScore))", "weather": "\(fmt(b.weatherScore))",
                "season": "\(fmt(b.seasonMultiplier))", "final": "\(fmt(b.finalScore))"
            ]
            logger.info("Scoring diag — point breakdown", metadata: ptMeta)
        }
    }

    /// Compact 3-decimal formatter for diagnostic log values.
    private func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

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
        db: any SQLDatabase,
        forecastCache: (any ForecastObsCache)? = nil
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

        // Fetch historical observations for the last 13 days via weatherClient.
        // weatherClient is a CachedWeatherClient (Redis → DB → OpenMeteo archive) that uses
        // the exact same coarse coordinates as the forecast grid — so the DB lookup hits.
        // Previously this queried the DB directly at forecast coarse coords, which never
        // matched the DB rows (stored at the archive API's snapped coords, ~0.07° grid),
        // leaving historicalByIndex always empty and every forecast day rain-window-less.
        let histRepo = WeatherRepository(db: db)
        let historicalByIndex: [Int: [DailyObservation]]
        do {
            let dailyBatch = try await weatherClient.fetchDailyBatch(coordinates: coords)
            var byIndex: [Int: [DailyObservation]] = [:]
            for (i, obs) in dailyBatch.enumerated() where !obs.isEmpty {
                byIndex[i] = obs
            }
            historicalByIndex = byIndex
            logger.info("Forecast — historical data loaded via weatherClient", metadata: [
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

        // Fetch forecast observations: check Redis cache first, only call API for misses.
        // Key: "forecast_obs:<lat>:<lon>:<baseDate>", TTL 23h.
        // This avoids re-fetching ~4037 points on every run (same daily quota as historical).
        let apiBatchSize = 50
        var forecastByCoord = [[DailyObservation]](repeating: [], count: coarsePoints.count)

        // L1: Redis — populate hits, collect miss indices
        var apiMissIndices: [Int] = []
        if let cache = forecastCache {
            for (i, coord) in coarsePoints.enumerated() {
                let key = "forecast_obs:\(coord.lat):\(coord.lon):\(baseDate)"
                if let cached = try? await cache.get(key: key) {
                    forecastByCoord[i] = cached
                } else {
                    apiMissIndices.append(i)
                }
            }
        } else {
            apiMissIndices = Array(coarsePoints.indices)
        }

        let cacheHits = coarsePoints.count - apiMissIndices.count
        if cacheHits > 0 {
            logger.info("Forecast — cache hits", metadata: [
                "cached": "\(cacheHits)",
                "apiNeeded": "\(apiMissIndices.count)"
            ])
        }

        // L2: API — sequential fetch for cache misses
        let totalBatches = (apiMissIndices.count + apiBatchSize - 1) / apiBatchSize
        let logInterval = max(1, totalBatches / 5)
        var dailyQuotaExhausted = false

        for (batchIdx, batchStart) in stride(from: 0, to: apiMissIndices.count, by: apiBatchSize).enumerated() {
            if dailyQuotaExhausted { break }

            let batchEnd = min(batchStart + apiBatchSize, apiMissIndices.count)
            let batchMissIndices = Array(apiMissIndices[batchStart..<batchEnd])
            let batchCoords = batchMissIndices.map { (latitude: coarsePoints[$0].lat, longitude: coarsePoints[$0].lon) }
            do {
                let results = try await openMeteoClient.fetchForecastDailyBatch(
                    coordinates: batchCoords,
                    forecastDays: forecastDaysToFetch
                )
                for (offset, obs) in results.enumerated() {
                    let coordIdx = batchMissIndices[offset]
                    forecastByCoord[coordIdx] = obs
                    // Store in Redis for next run (26h TTL — scheduler fires at 02:44 daily,
                    // 23h would expire at 01:44 next day, 1h before the next run)
                    if let cache = forecastCache, !obs.isEmpty {
                        let coord = coarsePoints[coordIdx]
                        let key = "forecast_obs:\(coord.lat):\(coord.lon):\(baseDate)"
                        try? await cache.set(key: key, observations: obs, ttl: 26 * 3600)
                    }
                }
            } catch WeatherFetchError.dailyQuotaExceeded {
                logger.error("Forecast — Open-Meteo daily quota exceeded, aborting remaining batches", metadata: [
                    "completedBatches": "\(batchIdx)",
                    "remainingBatches": "\(totalBatches - batchIdx)"
                ])
                dailyQuotaExhausted = true
            } catch {
                logger.warning("Forecast batch fetch failed — using empty weather for batch", metadata: [
                    "batchStart": "\(batchStart)",
                    "batchSize": "\(batchCoords.count)",
                    "error": "\(error)"
                ])
            }

            if totalBatches > 0 && ((batchIdx + 1) % logInterval == 0 || batchIdx + 1 == totalBatches) {
                let pct = Int(Double(batchIdx + 1) / Double(totalBatches) * 100)
                logger.info("Forecast — weather fetch progress", metadata: [
                    "progress": "\(pct)%",
                    "batch": "\(batchIdx + 1)/\(totalBatches)"
                ])
            }
        }

        logger.info("Forecast — Open-Meteo fetch complete", metadata: [
            "fetched": "\(forecastByCoord.filter { !$0.isEmpty }.count)/\(coarsePoints.count)",
            "fromCache": "\(cacheHits)",
            "fromAPI": "\(apiMissIndices.count)"
        ])

        // Persist forecast observations to weather_observations so the API can serve
        // /weather/daily?from=today&to=today+N with real forecast data.
        // ON CONFLICT DO NOTHING means re-runs are safe and stale historical data is not overwritten.
        let forecastEntries: [(lat: Double, lon: Double, observations: [DailyObservation])] = coarsePoints
            .enumerated()
            .compactMap { (i, cp) in
                let obs = forecastByCoord[i]
                guard !obs.isEmpty else { return nil }
                return (lat: cp.lat, lon: cp.lon, observations: obs)
            }
        if !forecastEntries.isEmpty {
            do {
                // Ensure partitions exist for all months that forecast days span
                let forecastEnd = Self.dateAddDays(baseDate, days)
                try await histRepo.ensurePartitions(from: baseDate, to: forecastEnd)
                try await histRepo.storeDailyObservations(entries: forecastEntries)
                logger.info("Forecast — persisted observations to DB", metadata: [
                    "coordinates": "\(forecastEntries.count)",
                    "dateRange": "\(baseDate)–\(forecastEnd)"
                ])
            } catch {
                logger.warning("Forecast — failed to persist observations to DB", metadata: ["error": "\(error)"])
            }
        }

        // Remove stale forecast directories (dates ≤ baseDate that are no longer future forecasts)
        let forecastRootPath = "Storage/tiles/forecast"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = TimeZone(identifier: "UTC")
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: forecastRootPath) {
            for entry in existing {
                if dateFmt.date(from: entry) != nil, entry <= baseDate {
                    let stale = "\(forecastRootPath)/\(entry)"
                    try? FileManager.default.removeItem(atPath: stale)
                    logger.info("Forecast — removed stale directory", metadata: ["dir": "\(entry)"])
                }
            }
        }

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
                let cp = coarsePoints[i]
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
            logScoringDiagnostics(engine: engine, inputs: inputs, results: results, date: forecastDate, dayOfYear: dayOfYear)

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
