import Foundation
import Logging
@preconcurrency import RediStack

protocol WeatherCache: Sendable {
    func get(key: String) async throws -> WeatherData?
    func set(key: String, value: WeatherData, ttl: Int) async throws
}

/// Cache for raw forecast observations per coordinate.
/// Stores [DailyObservation] (not aggregated) so the forecast pipeline
/// can reconstruct per-day weather without losing per-day variation.
protocol ForecastObsCache: Sendable {
    func get(key: String) async throws -> [DailyObservation]?
    func set(key: String, observations: [DailyObservation], ttl: Int) async throws
}

// @unchecked Sendable: same rationale as RedisWeatherCache below.
struct RedisForecastObsCache: ForecastObsCache, @unchecked Sendable {
    let redis: any RedisClient

    func get(key: String) async throws -> [DailyObservation]? {
        let value = try await redis.get(RedisKey(key), as: String.self).get()
        guard let json = value else { return nil }
        return try JSONDecoder().decode([DailyObservation].self, from: Data(json.utf8))
    }

    func set(key: String, observations: [DailyObservation], ttl: Int) async throws {
        let json = String(data: try JSONEncoder().encode(observations), encoding: .utf8)!
        _ = try await redis.set(RedisKey(key), to: json).get()
        _ = try await redis.expire(RedisKey(key), after: .seconds(Int64(ttl))).get()
    }
}

// @unchecked Sendable: RedisClient is pool-backed and thread-safe but RediStack doesn't declare Sendable conformance
struct RedisWeatherCache: WeatherCache, @unchecked Sendable {
    let redis: any RedisClient

    func get(key: String) async throws -> WeatherData? {
        let value = try await redis.get(RedisKey(key), as: String.self).get()
        guard let json = value else { return nil }
        return try JSONDecoder().decode(WeatherData.self, from: Data(json.utf8))
    }

    func set(key: String, value: WeatherData, ttl: Int) async throws {
        let json = String(data: try JSONEncoder().encode(value), encoding: .utf8)!
        _ = try await redis.set(RedisKey(key), to: json).get()
        _ = try await redis.expire(RedisKey(key), after: .seconds(Int64(ttl))).get()
    }
}

struct CachedWeatherClient: WeatherClient {
    private let inner: any WeatherClient
    private let cache: any WeatherCache
    private let repository: WeatherRepository?
    private let ttl: Int
    private let targetDate: String
    private let startDate: String
    /// Upper bound actually available from the archive API (targetDate - 2).
    /// Used as the ceiling for missing-day computations so incremental fetches
    /// never request a date the archive endpoint hasn't published yet.
    private let archiveEndDate: String
    private let expectedDays: Int
    private static let logger = Logger(label: "funghi.pipeline.weather.cache")

    init(
        inner: any WeatherClient,
        cache: any WeatherCache,
        ttl: Int,
        targetDate: String,
        repository: WeatherRepository? = nil
    ) {
        self.inner = inner
        self.cache = cache
        self.ttl = ttl
        self.targetDate = targetDate
        self.repository = repository

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let cal = Calendar(identifier: .gregorian)
        if let end = formatter.date(from: targetDate),
           let start = cal.date(byAdding: .day, value: -13, to: end),
           let archiveEnd = cal.date(byAdding: .day, value: -2, to: end) {
            self.startDate = formatter.string(from: start)
            self.archiveEndDate = formatter.string(from: archiveEnd)
            // Count days inclusive up to archiveEnd (what the archive actually has)
            let days = cal.dateComponents([.day], from: start, to: archiveEnd).day ?? 11
            self.expectedDays = days + 1
        } else {
            self.startDate = targetDate
            self.archiveEndDate = targetDate
            self.expectedDays = 12
        }
    }

    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData {
        let daily = try await fetchDaily(latitude: latitude, longitude: longitude)
        return WeatherData.aggregate(from: daily)
    }

    func fetchDaily(latitude: Double, longitude: Double) async throws -> [DailyObservation] {
        let roundedLat = (latitude * 1000).rounded() / 1000
        let roundedLon = (longitude * 1000).rounded() / 1000
        let redisKey = "weather:\(roundedLat):\(roundedLon):\(targetDate)"

        // L1: Redis (stores aggregate — fast bypass for the whole daily flow)
        if let cached = try? await cache.get(key: redisKey) {
            return syntheticObservations(from: cached)
        }

        // L2: PostgreSQL — check for daily data (complete or partial)
        if let repo = repository {
            let existing = try? await repo.fetchExistingDaily(
                coordinates: [(latitude: roundedLat, longitude: roundedLon)],
                from: startDate,
                to: archiveEndDate
            )
            if let obs = existing?[0], !obs.isEmpty {
                if obs.count >= expectedDays {
                    // Complete — use DB data directly
                    let aggregate = WeatherData.aggregate(from: obs)
                    try? await cache.set(key: redisKey, value: aggregate, ttl: ttl)
                    return obs
                }

                // Partial — fetch only missing days from API
                let existingDates = Set(obs.map(\.date))
                let allDates = Self.generateDateRange(from: startDate, to: archiveEndDate)
                let missingDates = allDates.filter { !existingDates.contains($0) }

                if !missingDates.isEmpty, let missStart = missingDates.min(), let missEnd = missingDates.max() {
                    Self.logger.info("Incremental weather fetch", metadata: [
                        "cached": "\(obs.count)",
                        "missing": "\(missingDates.count)",
                        "range": "\(missStart)...\(missEnd)"
                    ])
                    let newObs = try await inner.fetchDaily(
                        latitude: latitude, longitude: longitude,
                        startDate: missStart, endDate: missEnd
                    )
                    let newFiltered = newObs.filter { missingDates.contains($0.date) }
                    try? await repository?.storeDailyObservations(
                        entries: [(lat: roundedLat, lon: roundedLon, observations: newFiltered)]
                    )
                    let combined = (obs + newFiltered).sorted { $0.date < $1.date }
                    let aggregate = WeatherData.aggregate(from: combined)
                    try? await cache.set(key: redisKey, value: aggregate, ttl: ttl)
                    return combined
                }
            }
        }

        // L3: Full fetch from Open-Meteo API (no DB data at all)
        let daily = try await inner.fetchDaily(latitude: latitude, longitude: longitude)
        let aggregate = WeatherData.aggregate(from: daily)
        try? await cache.set(key: redisKey, value: aggregate, ttl: ttl)
        try? await repository?.storeDailyObservations(
            entries: [(lat: roundedLat, lon: roundedLon, observations: daily)]
        )
        return daily
    }

    func fetchBatch(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [WeatherData] {
        let rounded = coordinates.map { (
            latitude: (($0.latitude * 1000).rounded() / 1000),
            longitude: (($0.longitude * 1000).rounded() / 1000)
        ) }

        // Try Redis first — returns complete WeatherData (preserves maxRain2d, avgSoilTemp7d)
        var results = [WeatherData?](repeating: nil, count: coordinates.count)
        var missIndices: [Int] = []
        for (i, coord) in rounded.enumerated() {
            let key = "weather:\(coord.latitude):\(coord.longitude):\(targetDate)"
            if let cached = try? await cache.get(key: key) {
                results[i] = cached
            } else {
                missIndices.append(i)
            }
        }

        if missIndices.isEmpty {
            return results.map { $0! }
        }

        // Fetch remaining via daily pipeline (DB → API) and aggregate
        let missCoords = missIndices.map { coordinates[$0] }
        let dailyBatch = try await fetchDailyBatch(coordinates: missCoords)
        for (j, idx) in missIndices.enumerated() {
            results[idx] = WeatherData.aggregate(from: dailyBatch[j])
        }

        return results.map { $0! }
    }

    func fetchDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [[DailyObservation]] {
        let rounded = coordinates.map { (
            latitude: (($0.latitude * 1000).rounded() / 1000),
            longitude: (($0.longitude * 1000).rounded() / 1000)
        ) }

        // L1: Check Redis for each coordinate (aggregate cache)
        var results = [[DailyObservation]?](repeating: nil, count: coordinates.count)
        var redisMissIndices: [Int] = []

        for (i, coord) in rounded.enumerated() {
            let key = "weather:\(coord.latitude):\(coord.longitude):\(targetDate)"
            if let cached = try? await cache.get(key: key) {
                results[i] = syntheticObservations(from: cached)
            } else {
                redisMissIndices.append(i)
            }
        }

        if redisMissIndices.isEmpty {
            return results.map { $0! }
        }

        let redisHits = coordinates.count - redisMissIndices.count
        if redisHits > 0 {
            Self.logger.info("Weather cache: Redis hits", metadata: [
                "cached": "\(redisHits)",
                "remaining": "\(redisMissIndices.count)"
            ])
        }

        // L2: Check PostgreSQL for Redis misses — query daily observations
        var fullMissingIndices: [Int] = []  // No DB data at all → need full API fetch
        var partialIndices: [Int] = []       // Some DB data → need incremental fetch
        var partialObservations: [Int: [DailyObservation]] = [:]  // Cached partial data

        if let repo = repository {
            let uncachedCoords = redisMissIndices.map {
                (latitude: rounded[$0].latitude, longitude: rounded[$0].longitude)
            }
            if let dbResults = try? await repo.fetchExistingDaily(
                coordinates: uncachedCoords, from: startDate, to: archiveEndDate
            ) {
                for (j, idx) in redisMissIndices.enumerated() {
                    if let obs = dbResults[j], !obs.isEmpty {
                        if obs.count >= expectedDays {
                            // Complete DB hit
                            results[idx] = obs
                            let coord = rounded[idx]
                            let key = "weather:\(coord.latitude):\(coord.longitude):\(targetDate)"
                            let aggregate = WeatherData.aggregate(from: obs)
                            try? await cache.set(key: key, value: aggregate, ttl: ttl)
                        } else {
                            // Partial DB hit — need incremental fetch
                            partialIndices.append(idx)
                            partialObservations[idx] = obs
                        }
                    } else {
                        fullMissingIndices.append(idx)
                    }
                }

                let dbHits = redisMissIndices.count - fullMissingIndices.count - partialIndices.count
                if dbHits > 0 || !partialIndices.isEmpty {
                    Self.logger.info("Weather cache: DB results", metadata: [
                        "complete": "\(dbHits)",
                        "partial": "\(partialIndices.count)",
                        "missing": "\(fullMissingIndices.count)"
                    ])
                }
            } else {
                fullMissingIndices = redisMissIndices
            }
        } else {
            fullMissingIndices = redisMissIndices
        }

        // L2.5: Incremental fetch for partial DB hits — fetch only missing days
        if !partialIndices.isEmpty {
            let allDates = Self.generateDateRange(from: startDate, to: archiveEndDate)
            // Find the common set of missing dates (typically the same for all partials)
            let sampleExisting = Set(partialObservations[partialIndices[0]]!.map(\.date))
            let missingDates = allDates.filter { !sampleExisting.contains($0) }

            if !missingDates.isEmpty, let missStart = missingDates.min(), let missEnd = missingDates.max() {
                Self.logger.info("Incremental batch fetch", metadata: [
                    "coordinates": "\(partialIndices.count)",
                    "missingDays": "\(missingDates.count)",
                    "range": "\(missStart)...\(missEnd)"
                ])

                let partialCoords = partialIndices.map {
                    (latitude: rounded[$0].latitude, longitude: rounded[$0].longitude)
                }
                let fetched = try await inner.fetchDailyBatch(
                    coordinates: partialCoords,
                    startDate: missStart,
                    endDate: missEnd
                )

                let missingSet = Set(missingDates)
                var dbEntries: [(lat: Double, lon: Double, observations: [DailyObservation])] = []
                for (j, idx) in partialIndices.enumerated() {
                    let newObs = fetched[j].filter { missingSet.contains($0.date) }
                    let existing = partialObservations[idx]!
                    let combined = (existing + newObs).sorted { $0.date < $1.date }
                    results[idx] = combined
                    let coord = rounded[idx]
                    let key = "weather:\(coord.latitude):\(coord.longitude):\(targetDate)"
                    let aggregate = WeatherData.aggregate(from: combined)
                    try? await cache.set(key: key, value: aggregate, ttl: ttl)
                    dbEntries.append((lat: coord.latitude, lon: coord.longitude, observations: newObs))
                }
                try? await repository?.storeDailyObservations(entries: dbEntries)
            }
        }

        if fullMissingIndices.isEmpty && partialIndices.allSatisfy({ results[$0] != nil }) {
            return results.map { $0! }
        }

        // L3: Full fetch for coordinates with no DB data at all
        if !fullMissingIndices.isEmpty {
            let apiCoords = fullMissingIndices.map { rounded[$0] }
            let fetched = try await inner.fetchDailyBatch(coordinates: apiCoords)

            var dbEntries: [(lat: Double, lon: Double, observations: [DailyObservation])] = []
            for (j, idx) in fullMissingIndices.enumerated() {
                let daily = fetched[j]
                results[idx] = daily
                let coord = rounded[idx]
                let key = "weather:\(coord.latitude):\(coord.longitude):\(targetDate)"
                let aggregate = WeatherData.aggregate(from: daily)
                try? await cache.set(key: key, value: aggregate, ttl: ttl)
                dbEntries.append((lat: coord.latitude, lon: coord.longitude, observations: daily))
            }
            try? await repository?.storeDailyObservations(entries: dbEntries)
        }

        return results.map { $0! }
    }

    /// Generate all "YYYY-MM-DD" date strings in a range (inclusive).
    static func generateDateRange(from start: String, to end: String) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let startDate = formatter.date(from: start),
              let endDate = formatter.date(from: end) else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dates: [String] = []
        var current = startDate
        while current <= endDate {
            dates.append(formatter.string(from: current))
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return dates
    }

    /// Create synthetic daily observations from an aggregate for Redis-cached results.
    /// These are used when the caller only needs the aggregate anyway (which is the
    /// common pipeline path). The values aren't true daily data but aggregate correctly.
    private func syntheticObservations(from data: WeatherData) -> [DailyObservation] {
        // Distribute rain evenly across 14 days, use avg temp/humidity/soilTemp for each day.
        // This aggregates back to the same WeatherData values.
        let dailyRain = data.rain14d / Double(expectedDays)
        return (0..<expectedDays).map { _ in
            DailyObservation(
                date: "",
                rainMm: dailyRain,
                tempMeanC: data.avgTemperature,
                humidityPct: data.avgHumidity,
                soilTempC: data.avgSoilTemp7d
            )
        }
    }
}
