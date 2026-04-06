import Fluent
import Foundation
import Logging
import SQLKit
import Vapor

/// Evaluates forecast scores at each user's POI locations and sends APNs push
/// notifications when conditions look good. Run once daily after the forecast pipeline.
///
/// Logic:
///   - For each of the next `forecastDays` days (default 5):
///     - Load the forecast score raster from Storage/tiles/forecast/{date}/raster.bin
///     - For each user POI:
///       - Sample the score at the POI's lat/lon
///       - If score ≥ threshold AND no notification sent yet for (poi_id, forecast_date):
///         - Send APNs push to the user's device_token
///         - Record in poi_notifications (deduplication)
struct ForecastEvaluatorCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "days", help: "Number of forecast days to evaluate (default: 5)")
        var days: Int?

        @Option(name: "threshold", help: "Minimum score 0–100 to trigger notification (default: 45)")
        var threshold: Int?

        @Option(name: "base-date", help: "Base date YYYY-MM-DD (default: today Rome timezone)")
        var baseDate: String?
    }

    var help: String { "Evaluate forecast scores at POIs and send push notifications." }

    private let logger = Logger(label: "funghi.evaluator")

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let db = app.db
        let days = signature.days ?? 5
        let threshold = Double(signature.threshold ?? 45) / 100.0
        let baseDate = signature.baseDate ?? Self.todayString()

        logger.info("Forecast evaluator starting", metadata: [
            "baseDate": "\(baseDate)",
            "days": "\(days)",
            "threshold": "\(Int(threshold * 100))"
        ])

        guard let apns = APNsService(httpClient: app.http.client.shared) else {
            logger.warning("APNs not configured — skipping notifications")
            return
        }

        // Load all POIs with their owners' device tokens
        let pois = try await POI.query(on: db)
            .with(\.$user)
            .all()

        guard !pois.isEmpty else {
            logger.info("No POIs found, nothing to evaluate")
            return
        }

        logger.info("Evaluating POIs", metadata: ["count": "\(pois.count)"])

        var notificationsSent = 0
        var notificationsSkipped = 0

        for dayOffset in 1...days {
            let forecastDate = PipelineRunner.dateAddDays(baseDate, dayOffset)

            // Load forecast raster for this date
            let rasterPath = "Storage/tiles/forecast/\(forecastDate)/raster.bin"
            guard let cached = await RasterCache.shared.get(
                date: "forecast/\(forecastDate)",
                basePath: "Storage/tiles"
            ) else {
                logger.warning("No forecast raster found, skipping", metadata: ["date": "\(forecastDate)"])
                continue
            }
            let raster = cached.raster

            for poi in pois {
                guard let deviceToken = poi.user.deviceToken, !deviceToken.isEmpty else {
                    continue // User has no device registered
                }
                guard let poiID = poi.id else { continue }

                // Check if we already notified for this (poi, date)
                let alreadySent = try await POINotification.query(on: db)
                    .filter(\.$poi.$id == poiID)
                    .filter(\.$forecastDate == forecastDate)
                    .count() > 0

                if alreadySent {
                    notificationsSkipped += 1
                    continue
                }

                // Sample score at POI location
                guard let score = raster.sample(latitude: poi.latitude, longitude: poi.longitude),
                      score >= threshold
                else {
                    continue
                }

                // Build human-friendly date string
                let dateLabel = Self.italianDateLabel(forecastDate, daysFromNow: dayOffset)
                let title = "🍄 \(poi.name)"
                let body: String
                switch dayOffset {
                case 1: body = "Domani ottime condizioni! Vai a controllare la tua zona."
                case 2: body = "Dopodomani si preannuncia perfetto per i funghi."
                default: body = "\(dateLabel) ottime previsioni per i funghi!"
                }

                do {
                    try await apns.send(
                        to: deviceToken,
                        title: title,
                        body: body,
                        data: [
                            "type": "forecast",
                            "poi_id": poiID.uuidString,
                            "forecast_date": forecastDate,
                            "score": "\(Int((score * 100).rounded()))"
                        ]
                    )

                    // Record notification to avoid duplicates
                    let record = POINotification(poiID: poiID, forecastDate: forecastDate)
                    try await record.save(on: db)
                    notificationsSent += 1

                    logger.info("Notification sent", metadata: [
                        "poi": "\(poi.name)",
                        "date": "\(forecastDate)",
                        "score": "\(Int((score * 100).rounded()))"
                    ])
                } catch {
                    logger.warning("Failed to send notification", metadata: [
                        "poi": "\(poi.name)",
                        "error": "\(error)"
                    ])
                }
            }
        }

        logger.info("Forecast evaluator complete", metadata: [
            "sent": "\(notificationsSent)",
            "skipped": "\(notificationsSkipped)"
        ])
    }

    // MARK: - Helpers

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "Europe/Rome")
        return fmt.string(from: Date())
    }

    private static func italianDateLabel(_ dateString: String, daysFromNow: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let date = fmt.date(from: dateString) else { return dateString }
        let display = DateFormatter()
        display.locale = Locale(identifier: "it_IT")
        display.dateFormat = "d MMMM"
        display.timeZone = TimeZone(identifier: "Europe/Rome")
        return display.string(from: date)
    }
}
