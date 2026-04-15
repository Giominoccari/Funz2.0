import Foundation
import Logging
import SQLKit
import Vapor

struct WeatherController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.weather")

    func boot(routes: RoutesBuilder) throws {
        let weather = routes.grouped("weather")
        weather.get("daily", use: getDaily)
        weather.get("range", use: getRange)
    }

    // MARK: - GET /weather/daily?lat=45.5&lon=11.2&from=2026-03-11&to=2026-03-25

    @Sendable
    func getDaily(req: Request) async throws -> DailyWeatherResponse {
        guard let latStr = req.query[String.self, at: "lat"],
              let lonStr = req.query[String.self, at: "lon"],
              let lat = Double(latStr),
              let lon = Double(lonStr) else {
            throw Abort(.badRequest, reason: "Missing or invalid 'lat' and 'lon' query parameters")
        }

        guard let from = req.query[String.self, at: "from"],
              let to = req.query[String.self, at: "to"] else {
            throw Abort(.badRequest, reason: "Missing 'from' and 'to' date parameters (YYYY-MM-DD)")
        }

        // Validate date format
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard dateFormatter.date(from: from) != nil,
              dateFormatter.date(from: to) != nil else {
            throw Abort(.badRequest, reason: "Dates must be in YYYY-MM-DD format")
        }

        guard let sqlDb = req.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database not available")
        }

        let repo = WeatherRepository(db: sqlDb)
        guard let result = try await repo.fetchForAPI(
            latitude: lat,
            longitude: lon,
            from: from,
            to: to
        ) else {
            throw Abort(.notFound, reason: "No weather data found near the requested location")
        }

        return DailyWeatherResponse(
            point: .init(latitude: result.latitude, longitude: result.longitude),
            daily: result.daily.map { day in
                .init(date: day.date, rainMm: day.rainMm, tempMeanC: day.tempMeanC, humidityPct: day.humidityPct)
            }
        )
    }
}

    // MARK: - GET /weather/range?lat=45.5&lon=11.2
    //
    // Returns the min and max dates for which weather data is available near the
    // requested coordinates. The iOS client should use this range (or a subset of it)
    // when calling /weather/daily to populate the historical charts.

    @Sendable
    func getRange(req: Request) async throws -> WeatherRangeResponse {
        guard let latStr = req.query[String.self, at: "lat"],
              let lonStr = req.query[String.self, at: "lon"],
              let lat = Double(latStr),
              let lon = Double(lonStr) else {
            throw Abort(.badRequest, reason: "Missing or invalid 'lat' and 'lon' query parameters")
        }

        guard let sqlDb = req.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database not available")
        }

        let repo = WeatherRepository(db: sqlDb)
        guard let range = try await repo.fetchAvailableRange(latitude: lat, longitude: lon) else {
            throw Abort(.notFound, reason: "No weather data found near the requested location")
        }

        return WeatherRangeResponse(from: range.from, to: range.to)
    }

// MARK: - Response DTOs

struct WeatherRangeResponse: Content {
    let from: String
    let to: String
}

struct DailyWeatherResponse: Content {
    let point: CoordinatePoint
    let daily: [DailyEntry]

    struct CoordinatePoint: Content {
        let latitude: Double
        let longitude: Double
    }

    struct DailyEntry: Content {
        let date: String
        let rainMm: Double
        let tempMeanC: Double
        let humidityPct: Double
    }
}
