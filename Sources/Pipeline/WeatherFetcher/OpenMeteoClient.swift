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

    init(httpClient: HTTPClient, targetDate: String, config: WeatherConfig) {
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
    }

    var startDate: String {
        computeStartDate(from: targetDate, daysBack: 13)
    }

    func fetchDaily(latitude: Double, longitude: Double) async throws -> [DailyObservation] {
        let roundedLat = (latitude * 1000).rounded() / 1000
        let roundedLon = (longitude * 1000).rounded() / 1000

        let start = startDate
        let urlString = "\(baseURL)?latitude=\(roundedLat)&longitude=\(roundedLon)"
            + "&start_date=\(start)&end_date=\(targetDate)"
            + "&daily=rain_sum,temperature_2m_mean,relative_humidity_2m_mean"
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
                        delay = 60_000 + Int.random(in: 0...5_000)
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

        return toDailyObservations(daily)
    }

    /// Fetch daily observations for multiple coordinates in a single API call.
    func fetchDailyBatch(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [[DailyObservation]] {
        guard !coordinates.isEmpty else { return [] }

        if coordinates.count == 1 {
            return [try await fetchDaily(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)]
        }

        let rounded = coordinates.map { (
            lat: (($0.latitude * 1000).rounded() / 1000),
            lon: (($0.longitude * 1000).rounded() / 1000)
        ) }

        let lats = rounded.map { "\($0.lat)" }.joined(separator: ",")
        let lons = rounded.map { "\($0.lon)" }.joined(separator: ",")

        let start = startDate
        let urlString = "\(baseURL)?latitude=\(lats)&longitude=\(lons)"
            + "&start_date=\(start)&end_date=\(targetDate)"
            + "&daily=rain_sum,temperature_2m_mean,relative_humidity_2m_mean"
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

                    // Open-Meteo 429 = "Minutely API request limit exceeded. Try again in one minute."
                    // Wait 60s on 429 (per-minute limit), exponential backoff on 5xx
                    let delay: Int
                    if status == 429 {
                        delay = 60_000 + Int.random(in: 0...5_000)
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

        return responses.map { toDailyObservations($0.daily) }
    }

    // MARK: - Helpers

    private static func toDailyObservations(_ daily: OpenMeteoResponse.DailyData) -> [DailyObservation] {
        (0..<daily.time.count).map { i in
            DailyObservation(
                date: daily.time[i],
                rainMm: daily.rainSum[i] ?? 0,
                tempMeanC: daily.temperature2mMean[i] ?? 0,
                humidityPct: daily.relativeHumidity2mMean[i] ?? 0
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
