import Foundation
import Logging
@preconcurrency import RediStack

protocol WeatherCache: Sendable {
    func get(key: String) async throws -> WeatherData?
    func set(key: String, value: WeatherData, ttl: Int) async throws
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

        // Compute the 14-day range
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        if let end = formatter.date(from: targetDate),
           let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -13, to: end) {
            self.startDate = formatter.string(from: start)
            // Count days inclusive
            let days = Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day ?? 13
            self.expectedDays = days + 1
        } else {
            self.startDate = targetDate
            self.expectedDays = 14
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
            // Return a single pseudo-observation; callers that need real daily data
            // will go through fetchDailyBatch which checks DB first
            return syntheticObservations(from: cached)
        }

        // L2: PostgreSQL — check for complete daily data
        if let repo = repository {
            let existing = try? await repo.fetchExistingDaily(
                coordinates: [(latitude: roundedLat, longitude: roundedLon)],
                from: startDate,
                to: targetDate
            )
            if let obs = existing?[0], obs.count >= expectedDays {
                let aggregate = WeatherData.aggregate(from: obs)
                try? await cache.set(key: redisKey, value: aggregate, ttl: ttl)
                return obs
            }
        }

        // L3: Open-Meteo API
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
        let dailyBatch = try await fetchDailyBatch(coordinates: coordinates)
        return dailyBatch.map { WeatherData.aggregate(from: $0) }
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
        var stillMissingIndices = redisMissIndices
        if let repo = repository {
            let uncachedCoords = redisMissIndices.map {
                (latitude: rounded[$0].latitude, longitude: rounded[$0].longitude)
            }
            if let dbResults = try? await repo.fetchExistingDaily(
                coordinates: uncachedCoords, from: startDate, to: targetDate
            ) {
                var newStillMissing: [Int] = []
                for (j, idx) in redisMissIndices.enumerated() {
                    if let obs = dbResults[j], obs.count >= expectedDays {
                        results[idx] = obs
                        // Backfill Redis with aggregate
                        let coord = rounded[idx]
                        let key = "weather:\(coord.latitude):\(coord.longitude):\(targetDate)"
                        let aggregate = WeatherData.aggregate(from: obs)
                        try? await cache.set(key: key, value: aggregate, ttl: ttl)
                    } else {
                        newStillMissing.append(idx)
                    }
                }
                stillMissingIndices = newStillMissing

                let dbHits = redisMissIndices.count - stillMissingIndices.count
                if dbHits > 0 {
                    Self.logger.info("Weather cache: DB hits", metadata: [
                        "dbCached": "\(dbHits)",
                        "remaining": "\(stillMissingIndices.count)"
                    ])
                }
            }
        }

        if stillMissingIndices.isEmpty {
            return results.map { $0! }
        }

        // L3: Fetch remaining from Open-Meteo API as daily observations
        let apiCoords = stillMissingIndices.map { rounded[$0] }
        let fetched = try await inner.fetchDailyBatch(coordinates: apiCoords)

        // Store daily observations in DB + aggregate in Redis
        var dbEntries: [(lat: Double, lon: Double, observations: [DailyObservation])] = []
        for (j, idx) in stillMissingIndices.enumerated() {
            let daily = fetched[j]
            results[idx] = daily
            let coord = rounded[idx]
            let key = "weather:\(coord.latitude):\(coord.longitude):\(targetDate)"
            let aggregate = WeatherData.aggregate(from: daily)
            try? await cache.set(key: key, value: aggregate, ttl: ttl)
            dbEntries.append((lat: coord.latitude, lon: coord.longitude, observations: daily))
        }
        try? await repository?.storeDailyObservations(entries: dbEntries)

        return results.map { $0! }
    }

    /// Create synthetic daily observations from an aggregate for Redis-cached results.
    /// These are used when the caller only needs the aggregate anyway (which is the
    /// common pipeline path). The values aren't true daily data but aggregate correctly.
    private func syntheticObservations(from data: WeatherData) -> [DailyObservation] {
        // Distribute rain evenly across 14 days, use avg temp/humidity for each day.
        // This aggregates back to the same WeatherData values.
        let dailyRain = data.rain14d / Double(expectedDays)
        return (0..<expectedDays).map { _ in
            DailyObservation(
                date: "",
                rainMm: dailyRain,
                tempMeanC: data.avgTemperature,
                humidityPct: data.avgHumidity
            )
        }
    }
}
