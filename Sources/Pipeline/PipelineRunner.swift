import Foundation
import Logging

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

    func run(bbox: BoundingBox) async throws -> [ScoringEngine.Result] {
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
        // Derive from actual land points instead of full bbox to skip sea areas
        let weatherStepDeg = 0.09
        var coarseCells: Set<String> = []
        var coarsePoints: [(lat: Double, lon: Double)] = []
        for p in points {
            let cellLat = (p.latitude / weatherStepDeg).rounded(.down) * weatherStepDeg
            let cellLon = (p.longitude / weatherStepDeg).rounded(.down) * weatherStepDeg
            let key = "\(cellLat),\(cellLon)"
            if coarseCells.insert(key).inserted {
                coarsePoints.append((cellLat, cellLon))
            }
        }

        logger.info("Weather coarse grid", metadata: [
            "coarsePoints": "\(coarsePoints.count)",
            "finePoints": "\(points.count)",
            "ratio": "\(String(format: "%.0f", Double(points.count) / Double(max(1, coarsePoints.count))))x reduction"
        ])

        // Fetch weather for coarse grid points using concurrent batch API calls.
        // Open-Meteo supports multiple coordinates per request (comma-separated),
        // so we send ~50 coordinates per API call instead of 1.
        // Batches are dispatched concurrently; the rate limiter + semaphore in
        // OpenMeteoClient throttle actual HTTP connections.
        let apiBatchSize = 50
        let totalApiBatches = (coarsePoints.count + apiBatchSize - 1) / apiBatchSize

        logger.info("Phase 3 — Weather fetch starting", metadata: [
            "coarsePoints": "\(coarsePoints.count)",
            "apiBatchSize": "\(apiBatchSize)",
            "totalApiCalls": "\(totalApiBatches)"
        ])

        // Build all batch ranges upfront
        var batchRanges: [(index: Int, start: Int, end: Int)] = []
        batchRanges.reserveCapacity(totalApiBatches)
        var bIdx = 0
        for batchStart in stride(from: 0, to: coarsePoints.count, by: apiBatchSize) {
            batchRanges.append((bIdx, batchStart, min(batchStart + apiBatchSize, coarsePoints.count)))
            bIdx += 1
        }

        // Snapshot coarse points for safe concurrent access (Swift 6 Sendable)
        let coarseSnapshot = coarsePoints

        // Fetch all batches concurrently (rate limiter controls actual throughput)
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

            // Collect results preserving order
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
        let failedCount = coarseWeather.filter { $0.data.rain14d == 0 && $0.data.avgTemperature == 0 && $0.data.avgHumidity == 0 }.count

        if failedCount > 0 {
            logger.warning("Weather fetch completed with failures", metadata: [
                "failed": "\(failedCount)",
                "total": "\(coarseSnapshot.count)"
            ])
        }

        // IDW-interpolate weather from coarse grid to each fine-grid point
        // using spatial bucketing for O(1) neighbor lookup instead of O(n) brute force.
        let weatherCellSize = 0.1 // ~10km cells, slightly larger than coarse step (0.09°)
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

            let centerLatCell = Int(floor(point.latitude / weatherCellSize))
            let centerLonCell = Int(floor(point.longitude / weatherCellSize))

            var weightedRain = 0.0
            var weightedTemp = 0.0
            var weightedHum = 0.0
            var totalWeight = 0.0
            var exactMatch = false

            // Search 3x3 neighboring cells (~9 coarse points instead of 15,812)
            outer: for dLat in -1...1 {
                for dLon in -1...1 {
                    let cellKey = (centerLatCell + dLat) * 100_000 + (centerLonCell + dLon)
                    guard let cellPoints = weatherGrid[cellKey] else { continue }
                    for cw in cellPoints {
                        let dLatDiff = point.latitude - cw.lat
                        let dLonDiff = point.longitude - cw.lon
                        let distSq = dLatDiff * dLatDiff + dLonDiff * dLonDiff

                        if distSq < 1e-12 {
                            weightedRain = cw.data.rain14d
                            weightedTemp = cw.data.avgTemperature
                            weightedHum = cw.data.avgHumidity
                            totalWeight = 1.0
                            exactMatch = true
                            break outer
                        }

                        let weight = 1.0 / (distSq * distSq) // power=4 for smoother falloff
                        weightedRain += weight * cw.data.rain14d
                        weightedTemp += weight * cw.data.avgTemperature
                        weightedHum += weight * cw.data.avgHumidity
                        totalWeight += weight
                    }
                }
            }

            if totalWeight > 0 {
                if exactMatch {
                    weatherMap[key] = WeatherData(
                        rain14d: weightedRain,
                        avgTemperature: weightedTemp,
                        avgHumidity: weightedHum
                    )
                } else {
                    weatherMap[key] = WeatherData(
                        rain14d: weightedRain / totalWeight,
                        avgTemperature: weightedTemp / totalWeight,
                        avgHumidity: weightedHum / totalWeight
                    )
                }
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

    // MARK: - Geo cache (static terrain data)
    //
    // Binary format: 35 bytes per point
    //   lat(8B) + lon(8B) + altitude(8B) + aspect(8B) + forestType(1B) + soilType(1B) + corineCode(1B)

    private static let cacheDir = ".cache"
    private static let recordSize = 35

    private static func geoCachePath(bbox: BoundingBox, spacing: Int) -> String {
        let key = "\(bbox.minLat)_\(bbox.maxLat)_\(bbox.minLon)_\(bbox.maxLon)_\(spacing)"
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
}
