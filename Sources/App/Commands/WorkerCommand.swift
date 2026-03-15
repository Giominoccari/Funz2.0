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
        let httpClient = app.http.client.shared
        let redis = RedisWeatherCache(redis: app.redis)

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

        let sqlDb = app.db as! any SQLDatabase
        let forestClient = PostGISForestClient(db: sqlDb)
        let altitudeClient = PostGISAltitudeClient(db: sqlDb)

        let runner = PipelineRunner(
            config: config.pipeline,
            weatherClient: weatherClient,
            forestClient: forestClient,
            altitudeClient: altitudeClient
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
