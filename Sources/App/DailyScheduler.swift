import Foundation
import Logging
import SQLKit
import Vapor

/// Runs the full pipeline once per day at 02:45 Europe/Rome, inside the API process.
/// Registered as a Vapor LifecycleHandler in configure.swift — starts and stops with the app.
///
/// Daily sequence:
///   1. Historical map  — today's probability map (scoring + tiles)
///   2. Forecast maps   — next 5 days (scoring + tiles)
///   3. Evaluate        — sample POI scores, send APNs push notifications
///
/// Each step is fault-tolerant: failure is logged but does not block subsequent steps.
///
/// @unchecked Sendable safety: `task` is written once in `didBoot` and cancelled in
/// `shutdown`. Both are called serially by Vapor's lifecycle — no concurrent access.
final class DailyScheduler: LifecycleHandler, @unchecked Sendable {
    private let logger = Logger(label: "funghi.scheduler")
    private var task: Task<Void, Never>?

    func didBoot(_ app: Application) throws {
        task = Task { [weak self] in
            await self?.runLoop(app: app)
        }
        let next = Self.nextTriggerISO()
        logger.info("Daily scheduler started", metadata: ["next_run": "\(next)"])
    }

    func shutdown(_ app: Application) {
        task?.cancel()
        logger.info("Daily scheduler stopped")
    }

    // MARK: - Loop

    private func runLoop(app: Application) async {
        while !Task.isCancelled {
            let delay = Self.secondsUntilNextTrigger()
            logger.info("Daily pipeline scheduled", metadata: [
                "next_run": "\(Self.nextTriggerISO())",
                "in_minutes": "\(delay / 60)"
            ])

            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                break // Task cancelled
            }

            guard !Task.isCancelled else { break }
            await runDailyPipeline(app: app)
        }
    }

    // MARK: - Pipeline

    private func runDailyPipeline(app: Application) async {
        let date = Self.todayRomeString()
        let runStart = ContinuousClock.now

        logger.info("════ Daily pipeline starting ════", metadata: ["date": "\(date)"])

        let config: AppConfig
        do {
            config = try ConfigLoader.load()
        } catch {
            logger.error("Failed to load config, aborting", metadata: ["error": "\(error)"])
            return
        }

        let sqlDb = app.db as! any SQLDatabase
        let geoClient = BatchGeoEnrichmentClient(db: sqlDb)

        // Step 0 — Cleanup historical tiles older than 2 days
        await step("cleanup old tiles") {
            let tilesDir = app.directory.workingDirectory + "Storage/tiles"
            let cutoff = Self.dateString(daysBack: 2, from: date)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: tilesDir)) ?? []
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            for entry in contents where entry != "forecast" {
                guard fmt.date(from: entry) != nil, entry < cutoff else { continue }
                try FileManager.default.removeItem(atPath: "\(tilesDir)/\(entry)")
                logger.info("Scheduler — removed old tiles", metadata: ["dir": "\(entry)"])
            }
        }

        // Shared response logger — writes raw Open-Meteo JSON to Storage/logs/openmeteo/{date}/
        let responseLogger = OpenMeteoResponseLogger(date: date)

        // Step 1 — Historical map (today)
        await step("historical map") {
            let weatherRepo = WeatherRepository(db: sqlDb)
            let startDate = Self.dateString(daysBack: 13, from: date)
            try await weatherRepo.ensurePartitions(from: startDate, to: date)

            let openMeteo = OpenMeteoClient(
                httpClient: app.http.client.shared,
                targetDate: date,
                config: config.pipeline.weather,
                responseLogger: responseLogger
            )
            let weatherClient: any WeatherClient = CachedWeatherClient(
                inner: openMeteo,
                cache: RedisWeatherCache(redis: app.redis),
                ttl: config.pipeline.weather.cacheTTLSeconds,
                targetDate: date,
                repository: weatherRepo
            )
            let runner = PipelineRunner(
                config: config.pipeline,
                weatherClient: weatherClient,
                geoEnrichmentClient: geoClient,
                tileUploader: LocalTileUploader()
            )
            try await runner.runFull(bbox: .italy, date: date)
        }

        // Step 2 — Forecast maps (next 5 days)
        await step("forecast maps") {
            let openMeteo = OpenMeteoClient(
                httpClient: app.http.client.shared,
                targetDate: date,
                config: config.pipeline.weather,
                responseLogger: responseLogger
            )
            let runner = PipelineRunner(
                config: config.pipeline,
                weatherClient: MockWeatherClient(bbox: .italy, targetDate: date),
                geoEnrichmentClient: geoClient,
                tileUploader: LocalTileUploader()
            )
            let forecastCache = RedisForecastObsCache(redis: app.redis)
            try await runner.runForecast(
                bbox: .italy,
                baseDate: date,
                days: 5,
                openMeteoClient: openMeteo,
                db: sqlDb,
                forecastCache: forecastCache
            )
        }

        // Step 3 — Evaluate forecast scores + push notifications
        await step("evaluate + notify") {
            try await ForecastEvaluator.run(
                db: app.db,
                httpClient: app.http.client.shared,
                baseDate: date,
                days: 5,
                threshold: 0.45
            )
        }

        logger.info("════ Daily pipeline complete ════", metadata: [
            "date": "\(date)",
            "duration": "\(ContinuousClock.now - runStart)"
        ])
    }

    /// Runs a labelled step, logging outcome. Failure does not abort subsequent steps.
    private func step(_ label: String, _ body: () async throws -> Void) async {
        logger.info("Scheduler ▶ \(label)")
        do {
            try await body()
            logger.info("Scheduler ✔ \(label)")
        } catch {
            logger.error("Scheduler ✘ \(label) failed", metadata: ["error": "\(error)"])
        }
    }

    // MARK: - Timing

    /// Seconds from now until 02:45 Europe/Rome (today if in the future, else tomorrow).
    private static func secondsUntilNextTrigger() -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = 2
        components.minute = 45
        components.second = 0
        guard let todayTrigger = cal.date(from: components) else { return 86400 }
        let target = todayTrigger > now
            ? todayTrigger
            : cal.date(byAdding: .day, value: 1, to: todayTrigger) ?? todayTrigger
        return max(0, Int64(target.timeIntervalSince(now)))
    }

    private static func nextTriggerISO() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "Europe/Rome")!
        return fmt.string(from: Date(timeIntervalSinceNow: Double(secondsUntilNextTrigger())))
    }

    private static func todayRomeString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "Europe/Rome")
        return fmt.string(from: Date())
    }

    private static func dateString(daysBack: Int, from dateString: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let end = fmt.date(from: dateString),
              let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -daysBack, to: end)
        else { return dateString }
        return fmt.string(from: start)
    }
}
