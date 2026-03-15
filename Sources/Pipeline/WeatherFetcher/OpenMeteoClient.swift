import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat

struct OpenMeteoClient: WeatherClient {
    private let httpClient: HTTPClient
    private let baseURL: String
    private let targetDate: String
    private let retryMaxAttempts: Int
    private let retryBaseDelayMs: Int
    private let semaphore: AsyncSemaphore
    private static let logger = Logger(label: "funghi.pipeline.weather.openmeteo")

    init(httpClient: HTTPClient, targetDate: String, config: WeatherConfig) {
        self.httpClient = httpClient
        self.baseURL = config.baseURL
        self.targetDate = targetDate
        self.retryMaxAttempts = config.retryMaxAttempts
        self.retryBaseDelayMs = config.retryBaseDelayMs
        self.semaphore = AsyncSemaphore(value: config.maxConcurrentRequests)
    }

    func fetch(latitude: Double, longitude: Double) async throws -> WeatherData {
        let roundedLat = (latitude * 1000).rounded() / 1000
        let roundedLon = (longitude * 1000).rounded() / 1000

        let startDate = computeStartDate(from: targetDate, daysBack: 13)
        let urlString = "\(baseURL)?latitude=\(roundedLat)&longitude=\(roundedLon)"
            + "&start_date=\(startDate)&end_date=\(targetDate)"
            + "&daily=rain_sum,temperature_2m_mean,relative_humidity_2m_mean"
            + "&timezone=Europe%2FRome"

        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        var lastError: Error?
        for attempt in 0..<retryMaxAttempts {
            do {
                var request = HTTPClientRequest(url: urlString)
                request.method = .GET
                let response = try await httpClient.execute(request, timeout: .seconds(30))
                let status = response.status.code

                if status == 429 || status >= 500 {
                    lastError = WeatherFetchError.httpError(
                        statusCode: UInt(status), latitude: roundedLat, longitude: roundedLon
                    )
                    let delay = retryBaseDelayMs * (1 << attempt)
                    Self.logger.warning("Retrying weather fetch", metadata: [
                        "attempt": "\(attempt + 1)",
                        "status": "\(status)",
                        "delayMs": "\(delay)"
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
                return try Self.parseResponse(data, latitude: roundedLat, longitude: roundedLon)
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

    static func parseResponse(
        _ data: Data,
        latitude: Double,
        longitude: Double
    ) throws -> WeatherData {
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

        let rain14d = daily.rainSum.compactMap { $0 }.reduce(0, +)

        let last7Temps = Array(daily.temperature2mMean.suffix(7)).compactMap { $0 }
        let avgTemperature = last7Temps.isEmpty ? 0 : last7Temps.reduce(0, +) / Double(last7Temps.count)

        let last7Humidity = Array(daily.relativeHumidity2mMean.suffix(7)).compactMap { $0 }
        let avgHumidity = last7Humidity.isEmpty ? 0 : last7Humidity.reduce(0, +) / Double(last7Humidity.count)

        return WeatherData(
            rain14d: rain14d,
            avgTemperature: avgTemperature,
            avgHumidity: avgHumidity
        )
    }

    private func computeStartDate(from dateString: String, daysBack: Int) -> String {
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
