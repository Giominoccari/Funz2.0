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
    private let ttl: Int
    private let targetDate: String
    private static let logger = Logger(label: "funghi.pipeline.weather.cache")

    init(inner: any WeatherClient, cache: any WeatherCache, ttl: Int, targetDate: String) {
        self.inner = inner
        self.cache = cache
        self.ttl = ttl
        self.targetDate = targetDate
    }

    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData {
        let roundedLat = (latitude * 1000).rounded() / 1000
        let roundedLon = (longitude * 1000).rounded() / 1000
        let key = "weather:\(roundedLat):\(roundedLon):\(targetDate)"

        if let cached = try? await cache.get(key: key) {
            return cached
        }

        let data = try await inner.fetch(latitude: latitude, longitude: longitude)
        try? await cache.set(key: key, value: data, ttl: ttl)
        return data
    }
}
