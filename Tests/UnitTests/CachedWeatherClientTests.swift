import Foundation
import Testing
@testable import App

@Suite("CachedWeatherClient Tests")
struct CachedWeatherClientTests {

    /// Helper: 14 daily observations that aggregate to known values.
    static func makeDailyObs(
        dailyRain: Double = 3.0,
        temp: Double = 18.0,
        humidity: Double = 75.0
    ) -> [DailyObservation] {
        (0..<14).map { i in
            DailyObservation(
                date: "2026-03-\(String(format: "%02d", 1 + i))",
                rainMm: dailyRain,
                tempMeanC: temp,
                humidityPct: humidity
            )
        }
    }

    @Test("returns cached data on cache hit")
    func cacheHit() async throws {
        let cachedData = WeatherData(rain14d: 42.0, avgTemperature: 18.0, avgHumidity: 75.0)
        let cache = MockWeatherCache()
        let key = "weather:46.07:11.12:2026-03-14"
        try await cache.set(key: key, value: cachedData, ttl: 3600)

        let spy = SpyWeatherClient(dailyResult: Self.makeDailyObs())
        let client = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-14")

        let result = try await client.fetch(latitude: 46.07, longitude: 11.12)
        #expect(result.rain14d == 42.0)
        #expect(spy.fetchDailyCount == 0)
    }

    @Test("calls inner client on cache miss and stores result")
    func cacheMiss() async throws {
        let dailyObs = Self.makeDailyObs(dailyRain: 55.0 / 14.0, temp: 20.0, humidity: 80.0)
        let cache = MockWeatherCache()
        let spy = SpyWeatherClient(dailyResult: dailyObs)
        let client = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-14")

        let result = try await client.fetch(latitude: 46.07, longitude: 11.12)
        let expectedRain = (55.0 / 14.0) * 14.0
        #expect(abs(result.rain14d - expectedRain) < 0.001)
        #expect(spy.fetchDailyCount == 1)
        #expect(cache.setCallCount == 1)
    }

    @Test("cache key uses rounded coordinates")
    func roundedCoordinates() async throws {
        let cache = MockWeatherCache()
        let spy = SpyWeatherClient(dailyResult: Self.makeDailyObs())
        let client = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-14")

        // Slightly different coordinates that round to the same value
        _ = try await client.fetch(latitude: 46.0704, longitude: 11.1198)
        _ = try await client.fetch(latitude: 46.0701, longitude: 11.1202)

        // Second call should hit cache because rounded coords match
        #expect(spy.fetchDailyCount == 1)
    }

    @Test("cache key includes date")
    func dateInKey() async throws {
        let cache = MockWeatherCache()
        let spy = SpyWeatherClient(dailyResult: Self.makeDailyObs())

        let client1 = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-14")
        _ = try await client1.fetch(latitude: 46.07, longitude: 11.12)

        let client2 = CachedWeatherClient(inner: spy, cache: cache, ttl: 3600, targetDate: "2026-03-15")
        _ = try await client2.fetch(latitude: 46.07, longitude: 11.12)

        // Different dates → different cache keys → 2 inner fetches
        #expect(spy.fetchDailyCount == 2)
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
    private(set) var fetchDailyCount = 0
    let dailyResult: [DailyObservation]

    init(dailyResult: [DailyObservation]) { self.dailyResult = dailyResult }

    func fetchDaily(latitude: Double, longitude: Double) async throws -> [DailyObservation] {
        lock.withLock { fetchDailyCount += 1 }
        return dailyResult
    }
}
