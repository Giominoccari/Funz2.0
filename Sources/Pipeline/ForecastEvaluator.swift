import Fluent
import Foundation
import Logging
import Vapor

/// Evaluates forecast scores at each user's POI and sends APNs push notifications.
/// Shared between ForecastEvaluatorCommand (CLI) and DailyScheduler (automatic).
struct ForecastEvaluator {
    private static let logger = Logger(label: "funghi.evaluator")

    static func run(
        db: any Database,
        httpClient: HTTPClient,
        baseDate: String,
        days: Int = 5,
        threshold: Double = 0.45
    ) async throws {
        logger.info("Forecast evaluator starting", metadata: [
            "baseDate": "\(baseDate)",
            "days": "\(days)",
            "threshold": "\(Int(threshold * 100))"
        ])

        guard let apns = APNsService(httpClient: httpClient) else {
            logger.warning("APNs not configured — skipping notifications")
            return
        }

        let pois = try await POI.query(on: db).with(\.$user).all()
        guard !pois.isEmpty else {
            logger.info("No POIs found, nothing to evaluate")
            return
        }
        logger.info("Evaluating POIs", metadata: ["count": "\(pois.count)"])

        var sent = 0
        var skipped = 0

        for dayOffset in 1...days {
            let forecastDate = PipelineRunner.dateAddDays(baseDate, dayOffset)

            guard let cached = await RasterCache.shared.get(
                date: "forecast/\(forecastDate)",
                basePath: "Storage/tiles"
            ) else {
                logger.warning("No forecast raster found, skipping", metadata: ["date": "\(forecastDate)"])
                continue
            }
            let raster = cached.raster

            for poi in pois {
                guard let deviceToken = poi.user.deviceToken, !deviceToken.isEmpty,
                      let poiID = poi.id else { continue }

                let alreadySent = try await POINotification.query(on: db)
                    .filter(\.$poi.$id == poiID)
                    .filter(\.$forecastDate == forecastDate)
                    .count() > 0

                if alreadySent { skipped += 1; continue }

                guard let score = raster.sample(latitude: poi.latitude, longitude: poi.longitude),
                      score >= threshold else { continue }

                do {
                    try await apns.send(
                        to: deviceToken,
                        title: "🍄 \(poi.name)",
                        body: notificationBody(dayOffset: dayOffset, forecastDate: forecastDate),
                        data: [
                            "type": "forecast",
                            "poi_id": poiID.uuidString,
                            "forecast_date": forecastDate,
                            "score": "\(Int((score * 100).rounded()))"
                        ]
                    )
                    let record = POINotification(poiID: poiID, forecastDate: forecastDate)
                    try await record.save(on: db)
                    sent += 1
                    logger.info("Notification sent", metadata: [
                        "poi": "\(poi.name)",
                        "date": "\(forecastDate)",
                        "score": "\(Int((score * 100).rounded()))"
                    ])
                } catch {
                    logger.warning("Failed to send notification", metadata: [
                        "poi": "\(poi.name)", "error": "\(error)"
                    ])
                }
            }
        }

        logger.info("Forecast evaluator complete", metadata: ["sent": "\(sent)", "skipped": "\(skipped)"])
    }

    // MARK: - Helpers

    private static func notificationBody(dayOffset: Int, forecastDate: String) -> String {
        switch dayOffset {
        case 1: return "Domani ottime condizioni! Vai a controllare la tua zona."
        case 2: return "Dopodomani si preannuncia perfetto per i funghi."
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            let display = DateFormatter()
            display.locale = Locale(identifier: "it_IT")
            display.dateFormat = "d MMMM"
            display.timeZone = TimeZone(identifier: "Europe/Rome")
            if let date = fmt.date(from: forecastDate) {
                return "\(display.string(from: date)) ottime previsioni per i funghi!"
            }
            return "Ottime previsioni per i funghi!"
        }
    }
}
