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

        @Option(name: "mode", help: "Pipeline mode: 'historical' (default) or 'forecast'")
        var mode: String?

        @Option(name: "forecast-days", help: "Number of forecast days to generate (default: 5, max: 15)")
        var forecastDays: Int?

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
        let mode = signature.mode ?? "historical"

        logger.info("Worker starting pipeline", metadata: [
            "date": "\(date)",
            "bbox": "\(bbox)",
            "mode": "\(mode)"
        ])

        let config = try ConfigLoader.load()
        let sqlDb = app.db as! any SQLDatabase

        do {
            let pong = try await app.redis.ping().get()
            logger.info("Redis connected", metadata: ["ping": "\(pong)"])
        } catch {
            logger.warning("Redis not reachable, running without cache", metadata: ["error": "\(error)"])
        }

        var pipelineConfig = config.pipeline
        if let maxZoom = signature.maxZoom {
            logger.info("Overriding max zoom", metadata: ["maxZoom": "\(maxZoom)"])
            pipelineConfig.tileZoomMax = maxZoom
        }

        let geoClient = BatchGeoEnrichmentClient(db: sqlDb)
        let start = Date()

        if mode == "forecast" {
            let forecastDays = min(signature.forecastDays ?? 5, 15)
            logger.info("Forecast mode", metadata: ["days": "\(forecastDays)"])

            let openMeteoClient = OpenMeteoClient(
                httpClient: app.http.client.shared,
                targetDate: date,
                config: config.pipeline.weather
            )

            let runner = PipelineRunner(
                config: pipelineConfig,
                weatherClient: MockWeatherClient(bbox: bbox, targetDate: date), // unused in forecast mode
                geoEnrichmentClient: geoClient,
                tileUploader: LocalTileUploader()
            )

            let forecastCache = RedisForecastObsCache(redis: app.redis)
            try await runner.runForecast(
                bbox: bbox,
                baseDate: date,
                days: forecastDays,
                openMeteoClient: openMeteoClient,
                db: sqlDb,
                forecastCache: forecastCache
            )
        } else {
            let redis = RedisWeatherCache(redis: app.redis)
            let weatherRepo = WeatherRepository(db: sqlDb)

            let innerClient: any WeatherClient
            if signature.mockWeather {
                logger.info("Using mock weather data (--mock-weather flag)")
                innerClient = MockWeatherClient(bbox: bbox, targetDate: date)
            } else {
                innerClient = OpenMeteoClient(
                    httpClient: app.http.client.shared,
                    targetDate: date,
                    config: config.pipeline.weather
                )
            }

            let startDate = Self.dateString(daysBack: 13, from: date)
            do {
                try await weatherRepo.ensurePartitions(from: startDate, to: date)
            } catch {
                logger.warning("Failed to create weather partitions", metadata: [
                    "error": "\(String(reflecting: error))"
                ])
            }

            let weatherClient: any WeatherClient = CachedWeatherClient(
                inner: innerClient,
                cache: redis,
                ttl: config.pipeline.weather.cacheTTLSeconds,
                targetDate: date,
                repository: weatherRepo
            )

            let runner = PipelineRunner(
                config: pipelineConfig,
                weatherClient: weatherClient,
                geoEnrichmentClient: geoClient,
                tileUploader: LocalTileUploader()
            )

            try await runner.runFull(bbox: bbox, date: date)
        }

        let elapsed = Date().timeIntervalSince(start)
        logger.info("Worker pipeline completed", metadata: [
            "date": "\(date)",
            "mode": "\(mode)",
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

    private static func dateString(daysBack: Int, from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let end = formatter.date(from: dateString),
              let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -daysBack, to: end) else {
            return dateString
        }
        return formatter.string(from: start)
    }
}
