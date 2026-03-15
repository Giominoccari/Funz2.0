import Foundation
import Testing
@testable import App

@Suite("CachedWeatherClient Tests")
struct CachedWeatherClientTests {

    @Test("returns cached data on cache hit")
    func cacheHit() async throws {
        let cachedData = WeatherData(rain14d: 42.0, avgTemperature: 18.0, avgHumidity: 75.0)
        let cache = MockWeatherCache()
        let key = "weather:46.07:11.12:2026-03-14"
        try await cache.set(key: key, value: cachedData, ttl: 3600)

        let spy = SpyWeatherClient(result: WeatherData(rain14d: 0, avgTemperature: 0, avgHumidity: 0))
        let client = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-14")

        let result = try await client.fetch(latitude: 46.07, longitude: 11.12)
        #expect(result.rain14d == 42.0)
        #expect(spy.fetchCount == 0)
    }

    @Test("calls inner client on cache miss and stores result")
    func cacheMiss() async throws {
        let expected = WeatherData(rain14d: 55.0, avgTemperature: 20.0, avgHumidity: 80.0)
        let cache = MockWeatherCache()
        let spy = SpyWeatherClient(result: expected)
        let client = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-14")

        let result = try await client.fetch(latitude: 46.07, longitude: 11.12)
        #expect(result.rain14d == 55.0)
        #expect(spy.fetchCount == 1)
        #expect(cache.setCallCount == 1)
    }

    @Test("cache key uses rounded coordinates")
    func roundedCoordinates() async throws {
        let cache = MockWeatherCache()
        let spy = SpyWeatherClient(result: WeatherData(rain14d: 10, avgTemperature: 15, avgHumidity: 60))
        let client = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-14")

        // Slightly different coordinates that round to the same value
        _ = try await client.fetch(latitude: 46.0704, longitude: 11.1198)
        _ = try await client.fetch(latitude: 46.0701, longitude: 11.1202)

        // Second call should hit cache because rounded coords match
        #expect(spy.fetchCount == 1)
    }

    @Test("cache key includes date")
    func dateInKey() async throws {
        let cache = MockWeatherCache()
        let spy = SpyWeatherClient(result: WeatherData(rain14d: 10, avgTemperature: 15, avgHumidity: 60))

        let client1 = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-14")
        _ = try await client1.fetch(latitude: 46.07, longitude: 11.12)

        let client2 = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-15")
        _ = try await client2.fetch(latitude: 46.07, longitude: 11.12)

        // Different dates → different cache keys → 2 inner fetches
        #expect(spy.fetchCount == 2)
    }
}

// MARK: - Test Doubles

final class MockWeatherCache: WeatherCache, @unchecked Sendable {
    // @unchecked Sendable: test-only mock with lock-protected mutable state
    private let lock = NSLock()
    private var store: [String: WeatherData] = [:]
    var getCallCount = 0
    var setCallCount = 0

    func get(key: String) async throws -> WeatherData? {
        lock.withLock {
            getCallCount += 1
            return store[key]
        }
    }

    func set(key: String, value: WeatherData, ttl: Int) async throws {
        lock.withLock {
            setCallCount += 1
            store[key] = value
        }
    }
}

final class SpyWeatherClient: WeatherClient, @unchecked Sendable {
    // @unchecked Sendable: test-only spy with lock-protected mutable state
    private let lock = NSLock()
    private(set) var fetchCount = 0
    let result: WeatherData

    init(result: WeatherData) { self.result = result }

    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData {
        lock.withLock { fetchCount += 1 }
        return result
    }
}
