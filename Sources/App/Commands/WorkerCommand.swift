import Logging
import SQLKit
import Vapor

/// Vapor command for running the pipeline as a standalone worker process.
/// Used by ECS Fargate scheduled tasks:
///   App worker --bbox italy --date 2026-03-15
struct WorkerCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "bbox", help: "Bounding box preset: 'italy' or 'trentino' (default: italy)")
        var bbox: String?

        @Option(name: "date", help: "Target date YYYY-MM-DD (default: today Rome timezone)")
        var date: String?

        @Option(name: "max-zoom", help: "Override max tile zoom level (default: from config)")
        var maxZoom: Int?

        @Flag(name: "mock-weather", help: "Use mock weather data instead of Open-Meteo API")
        var mockWeather: Bool
    }

    var help: String {
        "Run the scoring pipeline synchronously, then exit."
    }

    private let logger = Logger(label: "funghi.worker")

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application

        let date = signature.date ?? Self.todayString()
        let bbox = Self.parseBBox(signature.bbox)

        logger.info("Worker starting pipeline", metadata: [
            "date": "\(date)",
            "bbox": "\(bbox)"
        ])

        let config = try ConfigLoader.load()
        let sqlDb = app.db as! any SQLDatabase

        let weatherClient: any WeatherClient
        if signature.mockWeather {
            logger.info("Using mock weather data (--mock-weather flag)")
            weatherClient = MockWeatherClient(bbox: bbox)
        } else {
            let httpClient = app.http.client.shared

            // Verify Redis connectivity before pipeline
            do {
                let pong = try await app.redis.ping().get()
                logger.info("Redis connected", metadata: ["ping": "\(pong)"])
            } catch {
                logger.warning("Redis not reachable, running without cache", metadata: ["error": "\(error)"])
            }

            let redis = RedisWeatherCache(redis: app.redis)
            let weatherRepo = WeatherRepository(db: sqlDb)

            let openMeteo = OpenMeteoClient(
                httpClient: httpClient,
                targetDate: date,
                config: config.pipeline.weather
            )

            // Ensure partitions exist for the full 14-day observation window
            do {
                try await weatherRepo.ensurePartitions(from: openMeteo.startDate, to: date)
            } catch {
                logger.warning("Failed to create weather partitions", metadata: [
                    "error": "\(String(reflecting: error))"
                ])
            }
            weatherClient = CachedWeatherClient(
                inner: openMeteo,
                cache: redis,
                ttl: config.pipeline.weather.cacheTTLSeconds,
                targetDate: date,
                repository: weatherRepo
            )
        }

        var pipelineConfig = config.pipeline
        if let maxZoom = signature.maxZoom {
            logger.info("Overriding max zoom", metadata: ["maxZoom": "\(maxZoom)"])
            pipelineConfig.tileZoomMax = maxZoom
        }

        let geoClient = BatchGeoEnrichmentClient(db: sqlDb)

        let runner = PipelineRunner(
            config: pipelineConfig,
            weatherClient: weatherClient,
            geoEnrichmentClient: geoClient,
            tileUploader: LocalTileUploader()
        )

        let start = Date()
        try await runner.runFull(bbox: bbox, date: date)
        let elapsed = Date().timeIntervalSince(start)

        logger.info("Worker pipeline completed", metadata: [
            "date": "\(date)",
            "elapsed_seconds": "\(String(format: "%.1f", elapsed))"
        ])
    }

    private static func parseBBox(_ value: String?) -> BoundingBox {
        switch value?.lowercased() {
        case "trentino":
            return .trentino
        case "italy", .none:
            return .italy
        default:
            return .italy
        }
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Europe/Rome")
        return formatter.string(from: Date())
    }
}
