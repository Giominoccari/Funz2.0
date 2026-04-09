import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat

struct OpenMeteoClient: WeatherClient {
    private let httpClient: HTTPClient
    private let baseURL: String
    let targetDate: String
    private let retryMaxAttempts: Int
    private let retryBaseDelayMs: Int
    private let rateLimiter: TokenBucketRateLimiter
    private let concurrencySemaphore: AsyncSemaphore
    private static let logger = Logger(label: "funghi.pipeline.weather.openmeteo")
    /// When set, every successful API response body is written to a per-date JSON file.
    let responseLogger: OpenMeteoResponseLogger?

    init(httpClient: HTTPClient, targetDate: String, config: WeatherConfig, responseLogger: OpenMeteoResponseLogger? = nil) {
        self.httpClient = httpClient
        self.baseURL = config.baseURL
        self.targetDate = targetDate
        self.retryMaxAttempts = config.retryMaxAttempts
        self.retryBaseDelayMs = config.retryBaseDelayMs
        // Token bucket: smooth out requests to stay under Open-Meteo's rate limit
        // ~600 req/min free tier → target 8 req/s with burst of 5
        self.rateLimiter = TokenBucketRateLimiter(
            tokensPerSecond: Double(config.rateLimitPerSecond ?? 8),
            burst: config.rateLimitBurst ?? 5
        )
        // Concurrency cap: limit in-flight HTTP connections
        self.concurrencySemaphore = AsyncSemaphore(value: config.maxConcurrentRequests)
        self.responseLogger = responseLogger
    }

    var startDate: String {
        computeStartDate(from: targetDate, daysBack: 13)
    }

    func fetchDaily(latitude: Double, longitude: Double, startDate start: String, endDate end: String) async throws -> [DailyObservation] {
        try await fetchDailyInternal(latitude: latitude, longitude: longitude, start: start, end: end)
    }

    func fetchDaily(latitude: Double, longitude: Double) async throws -> [DailyObservation] {
        try await fetchDailyInternal(latitude: latitude, longitude: longitude, start: startDate, end: targetDate)
    }

    private func fetchDailyInternal(latitude: Double, longitude: Double, start: String, end: String) async throws -> [DailyObservation] {
        let roundedLat = (latitude * 1000).rounded() / 1000
        let roundedLon = (longitude * 1000).rounded() / 1000

        let urlString = "\(baseURL)?latitude=\(roundedLat)&longitude=\(roundedLon)"
            + "&start_date=\(start)&end_date=\(end)"
            + "&daily=rain_sum,temperature_2m_mean,relative_humidity_2m_mean"
            + "&hourly=soil_temperature_0_to_7cm"
            + "&timezone=Europe%2FRome"

        await rateLimiter.consume()
        await concurrencySemaphore.wait()
        defer { Task { await concurrencySemaphore.signal() } }

        var lastError: Error?
        for attempt in 0..<retryMaxAttempts {
            do {
                var request = HTTPClientRequest(url: urlString)
                request.method = .GET
                let response = try await httpClient.execute(request, timeout: .seconds(30))
                let status = response.status.code

                if status == 429 || status >= 500 {
                    let errorBody = try? await response.body.collect(upTo: 4096)
                    let errorText = errorBody.flatMap { String(buffer: $0) } ?? "no body"

                    lastError = WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: roundedLat, longitude: roundedLon
                    )
                    let delay: Int
                    if status == 429 {
                        delay = Self.rateLimitDelay(body: errorText)
                    } else {
                        let baseDelay = retryBaseDelayMs * (1 << attempt)
                        delay = baseDelay + Int.random(in: 0...(baseDelay / 2))
                    }
                    Self.logger.warning("Retrying weather fetch", metadata: [
                        "attempt": "\(attempt + 1)",
                        "status": "\(status)",
                        "delayMs": "\(delay)",
                        "responseBody": "\(errorText)"
                    ])
                    try await Task.sleep(for: .milliseconds(delay))
                    continue
                }

                guard (200..<300).contains(Int(status)) else {
                    throw WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: roundedLat, longitude: roundedLon
                    )
                }

                let body = try await response.body.collect(upTo: 1024 * 256)
                let data = Data(buffer: body)
                return try Self.parseDailyResponse(data, latitude: roundedLat, longitude: roundedLon)
            } catch let error as WeatherFetchError {
                throw error
            } catch {
                lastError = error
                if attempt < retryMaxAttempts - 1 {
                    let delay = retryBaseDelayMs * (1 << attempt)
                    try await Task.sleep(for: .milliseconds(delay))
                }
            }
        }

        throw lastError ?? WeatherFetchError.noData(latitude: roundedLat, longitude: roundedLon)
    }

    /// Parse Open-Meteo single-coordinate response into daily observations.
    static func parseDailyResponse(
        _ data: Data,
        latitude: Double,
        longitude: Double
    ) throws -> [DailyObservation] {
        let response: OpenMeteoResponse
        do {
            response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        } catch {
            throw WeatherFetchError.decodingError(
                "\(error)", latitude: latitude, longitude: longitude
            )
        }

        let daily = response.daily
        guard !daily.time.isEmpty else {
            throw WeatherFetchError.noData(latitude: latitude, longitude: longitude)
        }

        return toDailyObservations(daily, hourly: response.hourly)
    }

    /// Fetch daily observations for multiple coordinates with a specific date range.
    func fetchDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)],
        startDate start: String,
        endDate end: String
    ) async throws -> [[DailyObservation]] {
        try await fetchDailyBatchInternal(coordinates: coordinates, start: start, end: end)
    }

    /// Fetch daily observations for multiple coordinates in a single API call.
    func fetchDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [[DailyObservation]] {
        try await fetchDailyBatchInternal(coordinates: coordinates, start: startDate, end: targetDate)
    }

    private func fetchDailyBatchInternal(
        coordinates: [(latitude: Double, longitude: Double)],
        start: String,
        end: String
    ) async throws -> [[DailyObservation]] {
        guard !coordinates.isEmpty else { return [] }

        if coordinates.count == 1 {
            return [try await fetchDailyInternal(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude, start: start, end: end)]
        }

        let rounded = coordinates.map { (
            lat: (($0.latitude * 1000).rounded() / 1000),
            lon: (($0.longitude * 1000).rounded() / 1000)
        ) }

        let lats = rounded.map { "\($0.lat)" }.joined(separator: ",")
        let lons = rounded.map { "\($0.lon)" }.joined(separator: ",")

        let urlString = "\(baseURL)?latitude=\(lats)&longitude=\(lons)"
            + "&start_date=\(start)&end_date=\(end)"
            + "&daily=rain_sum,temperature_2m_mean,relative_humidity_2m_mean"
            + "&hourly=soil_temperature_0_to_7cm"
            + "&timezone=Europe%2FRome"

        await rateLimiter.consume()
        await concurrencySemaphore.wait()
        defer { Task { await concurrencySemaphore.signal() } }

        var lastError: Error?
        for attempt in 0..<retryMaxAttempts {
            do {
                var request = HTTPClientRequest(url: urlString)
                request.method = .GET
                let response = try await httpClient.execute(request, timeout: .seconds(60))
                let status = response.status.code

                if status == 429 || status >= 500 {
                    let errorBody = try? await response.body.collect(upTo: 4096)
                    let errorText = errorBody.flatMap { String(buffer: $0) } ?? "no body"

                    lastError = WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: rounded[0].lat, longitude: rounded[0].lon
                    )

                    let delay: Int
                    if status == 429 {
                        delay = Self.rateLimitDelay(body: errorText)
                    } else {
                        let baseDelay = retryBaseDelayMs * (1 << attempt)
                        delay = baseDelay + Int.random(in: 0...(baseDelay / 2))
                    }
                    Self.logger.warning("Retrying batch weather fetch", metadata: [
                        "attempt": "\(attempt + 1)",
                        "status": "\(status)",
                        "batchSize": "\(coordinates.count)",
                        "delayMs": "\(delay)",
                        "responseBody": "\(errorText)"
                    ])
                    try await Task.sleep(for: .milliseconds(delay))
                    continue
                }

                guard (200..<300).contains(Int(status)) else {
                    throw WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: rounded[0].lat, longitude: rounded[0].lon
                    )
                }

                let maxSize = 1024 * 256 * coordinates.count
                let body = try await response.body.collect(upTo: maxSize)
                let data = Data(buffer: body)
                if let rl = responseLogger {
                    await rl.logHistorical(firstLat: rounded[0].lat, firstLon: rounded[0].lon, data: data)
                }
                return try Self.parseDailyBatchResponse(data, coordinates: rounded)
            } catch let error as WeatherFetchError {
                throw error
            } catch {
                lastError = error
                if attempt < retryMaxAttempts - 1 {
                    let delay = retryBaseDelayMs * (1 << attempt)
                    try await Task.sleep(for: .milliseconds(delay))
                }
            }
        }

        throw lastError ?? WeatherFetchError.noData(
            latitude: rounded[0].lat, longitude: rounded[0].lon
        )
    }

    /// Parse Open-Meteo multi-coordinate response into daily observations per coordinate.
    static func parseDailyBatchResponse(
        _ data: Data,
        coordinates: [(lat: Double, lon: Double)]
    ) throws -> [[DailyObservation]] {
        let responses: [OpenMeteoResponse]
        do {
            responses = try JSONDecoder().decode([OpenMeteoResponse].self, from: data)
        } catch {
            throw WeatherFetchError.decodingError(
                "Batch decode failed: \(error)",
                latitude: coordinates[0].lat,
                longitude: coordinates[0].lon
            )
        }

        guard responses.count == coordinates.count else {
            throw WeatherFetchError.decodingError(
                "Expected \(coordinates.count) results, got \(responses.count)",
                latitude: coordinates[0].lat,
                longitude: coordinates[0].lon
            )
        }

        return responses.map { toDailyObservations($0.daily, hourly: $0.hourly) }
    }

    // MARK: - Forecast

    /// Open-Meteo forecast endpoint (distinct from archive endpoint used for historical data).
    static let forecastBaseURL = "https://api.open-meteo.com/v1/forecast"

    /// Fetch forecast data for multiple coordinates in batches.
    /// Returns one array of DailyObservation per coordinate, with `forecastDays` entries each.
    /// Index 0 = today, index 1 = tomorrow, ..., index forecastDays-1 = the last forecast day.
    func fetchForecastDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)],
        forecastDays: Int = 6
    ) async throws -> [[DailyObservation]] {
        guard !coordinates.isEmpty else { return [] }

        if coordinates.count == 1 {
            let single = try await fetchForecastSingle(
                latitude: coordinates[0].latitude,
                longitude: coordinates[0].longitude,
                forecastDays: forecastDays
            )
            return [single]
        }

        let rounded = coordinates.map { (
            lat: (($0.latitude  * 1000).rounded() / 1000),
            lon: (($0.longitude * 1000).rounded() / 1000)
        ) }

        let lats = rounded.map { "\($0.lat)" }.joined(separator: ",")
        let lons = rounded.map { "\($0.lon)" }.joined(separator: ",")

        let urlString = "\(Self.forecastBaseURL)?latitude=\(lats)&longitude=\(lons)"
            + "&forecast_days=\(forecastDays)"
            + "&daily=rain_sum,temperature_2m_mean,relative_humidity_2m_mean"
            + "&hourly=soil_temperature_0_to_7cm"
            + "&timezone=Europe%2FRome"

        await rateLimiter.consume()
        await concurrencySemaphore.wait()
        defer { Task { await concurrencySemaphore.signal() } }

        var lastError: Error?
        for attempt in 0..<retryMaxAttempts {
            do {
                var request = HTTPClientRequest(url: urlString)
                request.method = .GET
                let response = try await httpClient.execute(request, timeout: .seconds(60))
                let status = response.status.code

                if status == 429 || status >= 500 {
                    let errorBody = try? await response.body.collect(upTo: 4096)
                    let errorText = errorBody.flatMap { String(buffer: $0) } ?? "no body"
                    lastError = WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: rounded[0].lat, longitude: rounded[0].lon
                    )
                    let delay: Int
                    if status == 429 {
                        delay = Self.rateLimitDelay(body: errorText)
                    } else {
                        let baseDelay = retryBaseDelayMs * (1 << attempt)
                        delay = baseDelay + Int.random(in: 0...(baseDelay / 2))
                    }
                    Self.logger.warning("Retrying forecast batch fetch", metadata: [
                        "attempt": "\(attempt + 1)",
                        "status": "\(status)",
                        "batchSize": "\(coordinates.count)",
                        "delayMs": "\(delay)",
                        "responseBody": "\(errorText)"
                    ])
                    try await Task.sleep(for: .milliseconds(delay))
                    continue
                }

                guard (200..<300).contains(Int(status)) else {
                    throw WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: rounded[0].lat, longitude: rounded[0].lon
                    )
                }

                let maxSize = 1024 * 256 * coordinates.count
                let body = try await response.body.collect(upTo: maxSize)
                let data = Data(buffer: body)
                if let rl = responseLogger {
                    await rl.logForecast(firstLat: rounded[0].lat, firstLon: rounded[0].lon, data: data)
                }
                return try Self.parseDailyBatchResponse(data, coordinates: rounded)
            } catch let error as WeatherFetchError {
                throw error
            } catch {
                lastError = error
                if attempt < retryMaxAttempts - 1 {
                    let delay = retryBaseDelayMs * (1 << attempt)
                    try await Task.sleep(for: .milliseconds(delay))
                }
            }
        }
        throw lastError ?? WeatherFetchError.noData(latitude: rounded[0].lat, longitude: rounded[0].lon)
    }

    private func fetchForecastSingle(
        latitude: Double, longitude: Double, forecastDays: Int
    ) async throws -> [DailyObservation] {
        let roundedLat = (latitude  * 1000).rounded() / 1000
        let roundedLon = (longitude * 1000).rounded() / 1000

        let urlString = "\(Self.forecastBaseURL)?latitude=\(roundedLat)&longitude=\(roundedLon)"
            + "&forecast_days=\(forecastDays)"
            + "&daily=rain_sum,temperature_2m_mean,relative_humidity_2m_mean"
            + "&hourly=soil_temperature_0_to_7cm"
            + "&timezone=Europe%2FRome"

        await rateLimiter.consume()
        await concurrencySemaphore.wait()
        defer { Task { await concurrencySemaphore.signal() } }

        var lastError: Error?
        for attempt in 0..<retryMaxAttempts {
            do {
                var request = HTTPClientRequest(url: urlString)
                request.method = .GET
                let response = try await httpClient.execute(request, timeout: .seconds(30))
                let status = response.status.code

                if status == 429 || status >= 500 {
                    let errorBody = try? await response.body.collect(upTo: 4096)
                    let errorText = errorBody.flatMap { String(buffer: $0) } ?? "no body"
                    lastError = WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: roundedLat, longitude: roundedLon
                    )
                    let delay = status == 429
                        ? Self.rateLimitDelay(body: errorText)
                        : retryBaseDelayMs * (1 << attempt) + Int.random(in: 0...(retryBaseDelayMs / 2))
                    try await Task.sleep(for: .milliseconds(delay))
                    continue
                }

                guard (200..<300).contains(Int(status)) else {
                    throw WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: roundedLat, longitude: roundedLon
                    )
                }

                let body = try await response.body.collect(upTo: 1024 * 256)
                let data = Data(buffer: body)
                return try Self.parseDailyResponse(data, latitude: roundedLat, longitude: roundedLon)
            } catch let error as WeatherFetchError {
                throw error
            } catch {
                lastError = error
                if attempt < retryMaxAttempts - 1 {
                    let delay = retryBaseDelayMs * (1 << attempt)
                    try await Task.sleep(for: .milliseconds(delay))
                }
            }
        }
        throw lastError ?? WeatherFetchError.noData(latitude: roundedLat, longitude: roundedLon)
    }

    // MARK: - Helpers

    /// Returns the appropriate retry delay in milliseconds for a 429 response.
    /// - Minutely limit: wait ~60s
    /// - Hourly limit: wait until the start of the next hour
    private static func rateLimitDelay(body: String) -> Int {
        if body.contains("Hourly") {
            // Wait until the next hour boundary (e.g. 8:47 → wait 13 minutes)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let now = Date()
            guard let nextHour = cal.nextDate(
                after: now,
                matching: DateComponents(minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) else {
                return 60_000 + Int.random(in: 0...5_000)
            }
            let msUntilNextHour = Int(nextHour.timeIntervalSince(now) * 1000)
            return msUntilNextHour + Int.random(in: 0...5_000)
        }
        // Minutely limit — wait ~60s
        return 60_000 + Int.random(in: 0...5_000)
    }

    /// Compute daily mean soil temperature from hourly data.
    /// Returns one value per day in `daily.time` order. Falls back to air temp if hourly data missing.
    private static func dailySoilTemps(
        hourly: OpenMeteoResponse.HourlyData?,
        daily: OpenMeteoResponse.DailyData
    ) -> [Double] {
        guard let hourly = hourly, !hourly.time.isEmpty else {
            // Fallback: estimate soil temp as slightly damped air temp
            return daily.temperature2mMean.map { ($0 ?? 0) * 0.85 }
        }

        // Group hourly values by date prefix (first 10 chars = "YYYY-MM-DD")
        var dailyMeans: [String: Double] = [:]
        var dailyCounts: [String: Int] = [:]
        for (i, timeStr) in hourly.time.enumerated() {
            guard let val = hourly.soilTemperature0To7cm[i] else { continue }
            let dateKey = String(timeStr.prefix(10))
            dailyMeans[dateKey, default: 0] += val
            dailyCounts[dateKey, default: 0] += 1
        }

        return daily.time.map { date in
            if let sum = dailyMeans[date], let count = dailyCounts[date], count > 0 {
                return sum / Double(count)
            }
            return 0
        }
    }

    private static func toDailyObservations(
        _ daily: OpenMeteoResponse.DailyData,
        hourly: OpenMeteoResponse.HourlyData?
    ) -> [DailyObservation] {
        let soilTemps = dailySoilTemps(hourly: hourly, daily: daily)
        return (0..<daily.time.count).map { i in
            DailyObservation(
                date: daily.time[i],
                rainMm: daily.rainSum[i] ?? 0,
                tempMeanC: daily.temperature2mMean[i] ?? 0,
                humidityPct: daily.relativeHumidity2mMean[i] ?? 0,
                soilTempC: i < soilTemps.count ? soilTemps[i] : 0
            )
        }
    }

    func computeStartDate(from dateString: String, daysBack: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: dateString) else {
            return dateString
        }
        let start = Calendar(identifier: .gregorian).date(
            byAdding: .day, value: -daysBack, to: date
        ) ?? date
        return formatter.string(from: start)
    }
}
