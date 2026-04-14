import Foundation
import Logging
import SQLKit
import Vapor

/// Runs the map pipeline and push notifications on separate daily schedules.
/// Registered as a Vapor LifecycleHandler in configure.swift — starts and stops with the app.
///
/// Pipeline task — 02:45 Europe/Rome:
///   1. Historical map  — today's probability map (scoring + tiles)
///   2. Forecast maps   — next 5 days (scoring + tiles)
///
/// Notification task — 12:00 Europe/Rome:
///   3. Evaluate        — sample POI scores, send APNs push notifications
///
/// Each step is fault-tolerant: failure is logged but does not block subsequent steps.
///
/// @unchecked Sendable safety: tasks are written once in `didBoot` and cancelled in
/// `shutdown`. Both are called serially by Vapor's lifecycle — no concurrent access.
final class DailyScheduler: LifecycleHandler, @unchecked Sendable {
    private let logger = Logger(label: "funghi.scheduler")
    private var task: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?

    func didBoot(_ app: Application) throws {
        let notifHour   = Environment.get("NOTIFICATION_HOUR").flatMap(Int.init) ?? 12
        let notifMinute = Environment.get("NOTIFICATION_MINUTE").flatMap(Int.init) ?? 0

        task = Task { [weak self] in
            await self?.runLoop(app: app)
        }
        notificationTask = Task { [weak self] in
            await self?.runNotificationLoop(app: app, hour: notifHour, minute: notifMinute)
        }
        logger.info("Daily scheduler started", metadata: [
            "next_pipeline": "\(Self.nextTriggerISO(hour: 2, minute: 45))",
            "next_notifications": "\(Self.nextTriggerISO(hour: notifHour, minute: notifMinute))"
        ])
    }

    func shutdown(_ app: Application) {
        task?.cancel()
        notificationTask?.cancel()
        logger.info("Daily scheduler stopped")
    }

    // MARK: - Loops

    private func runLoop(app: Application) async {
        while !Task.isCancelled {
            let delay = Self.secondsUntilNext(hour: 2, minute: 45)
            logger.info("Daily pipeline scheduled", metadata: [
                "next_run": "\(Self.nextTriggerISO(hour: 2, minute: 45))",
                "in_minutes": "\(delay / 60)"
            ])
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            guard !Task.isCancelled else { break }
            await runDailyPipeline(app: app)
        }
    }

    private func runNotificationLoop(app: Application, hour: Int, minute: Int) async {
        while !Task.isCancelled {
            let delay = Self.secondsUntilNext(hour: hour, minute: minute)
            logger.info("Notification run scheduled", metadata: [
                "next_run": "\(Self.nextTriggerISO(hour: hour, minute: minute))",
                "in_minutes": "\(delay / 60)"
            ])
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            guard !Task.isCancelled else { break }
            await runNotifications(app: app)
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

    // MARK: - Notifications-only run

    private func runNotifications(app: Application) async {
        let date = Self.todayRomeString()
        logger.info("════ Notification run starting ════", metadata: ["date": "\(date)"])
        await step("evaluate + notify") {
            try await ForecastEvaluator.run(
                db: app.db,
                httpClient: app.http.client.shared,
                baseDate: date,
                days: 5,
                threshold: 0.45
            )
        }
        logger.info("════ Notification run complete ════", metadata: ["date": "\(date)"])
    }

    // MARK: - Timing

    /// Seconds from now until the next occurrence of hour:minute in Europe/Rome.
    private static func secondsUntilNext(hour: Int, minute: Int) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let todayTrigger = cal.date(from: components) else { return 86400 }
        let target = todayTrigger > now
            ? todayTrigger
            : cal.date(byAdding: .day, value: 1, to: todayTrigger) ?? todayTrigger
        return max(0, Int64(target.timeIntervalSince(now)))
    }

    private static func nextTriggerISO(hour: Int, minute: Int) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "Europe/Rome")!
        return fmt.string(from: Date(timeIntervalSinceNow: Double(secondsUntilNext(hour: hour, minute: minute))))
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
