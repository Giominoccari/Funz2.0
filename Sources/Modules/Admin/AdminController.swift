import Logging
import SQLKit
import Vapor

struct AdminController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.admin")

    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin").grouped(AdminKeyMiddleware())
        admin.post("pipeline", "run", use: triggerPipeline)
    }

    @Sendable
    func triggerPipeline(req: Request) async throws -> Response {
        let params = try? req.content.decode(PipelineTriggerRequest.self)
        let date = params?.date ?? Self.todayString()
        let bbox = params?.bbox.map {
            BoundingBox(minLat: $0.minLat, maxLat: $0.maxLat, minLon: $0.minLon, maxLon: $0.maxLon)
        } ?? BoundingBox.trentino

        let config = try ConfigLoader.load()
        let httpClient = req.application.http.client.shared
        let redis = RedisWeatherCache(redis: req.application.redis)

        // Weather client: OpenMeteo → Redis cache
        let openMeteo = OpenMeteoClient(
            httpClient: httpClient,
            targetDate: date,
            config: config.pipeline.weather
        )
        let weatherClient = CachedWeatherClient(
            inner: openMeteo,
            cache: redis,
            ttl: config.pipeline.weather.cacheTTLSeconds,
            targetDate: date
        )

        // Forest/soil + altitude clients: PostGIS raster
        let sqlDb = req.db as! any SQLDatabase
        let forestClient = PostGISForestClient(db: sqlDb)

        // Altitude client: PostGIS raster (Copernicus DEM)
        let altitudeClient = PostGISAltitudeClient(db: sqlDb)

        Self.logger.info("Pipeline triggered", metadata: [
            "date": "\(date)",
            "bbox": "\(bbox)"
        ])

        Task {
            do {
                let runner = PipelineRunner(
                    config: config.pipeline,
                    weatherClient: weatherClient,
                    forestClient: forestClient,
                    altitudeClient: altitudeClient
                )
                try await runner.runFull(bbox: bbox, date: date)
                Self.logger.info("Pipeline run completed", metadata: ["date": "\(date)"])
            } catch {
                Self.logger.error("Pipeline run failed", metadata: [
                    "date": "\(date)",
                    "error": "\(error)"
                ])
            }
        }

        let response = PipelineTriggerResponse(
            status: "accepted",
            date: date,
            message: "Pipeline run started asynchronously"
        )
        return try await response.encodeResponse(status: .accepted, for: req)
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Europe/Rome")
        return formatter.string(from: Date())
    }
}

struct PipelineTriggerRequest: Content {
    var bbox: BBoxDTO?
    var date: String?
}

struct BBoxDTO: Content {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
}

struct PipelineTriggerResponse: Content {
    let status: String
    let date: String
    let message: String
}
