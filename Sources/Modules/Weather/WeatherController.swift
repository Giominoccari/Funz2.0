import Foundation
import Logging
import SQLKit
import Vapor

struct WeatherController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.weather")

    func boot(routes: RoutesBuilder) throws {
        let weather = routes.grouped("weather")
        weather.get("daily", use: getDaily)
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

// MARK: - Response DTOs

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
