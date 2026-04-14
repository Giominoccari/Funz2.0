import Fluent
import Foundation
import Logging
import Vapor

/// Evaluates forecast scores at each user's POI and sends APNs push notifications.
/// Shared between ForecastEvaluatorCommand (CLI) and DailyScheduler (automatic).
struct ForecastEvaluator {
    private static let logger = Logger(label: "funghi.evaluator")

    // Minimum absolute change in score (0–1) to be considered a meaningful trend.
    private static let trendThreshold = 0.07

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

                // Skip if already sent today for this forecast date.
                let alreadySent = try await POINotification.query(on: db)
                    .filter(\.$poi.$id == poiID)
                    .filter(\.$forecastDate == forecastDate)
                    .filter(\.$sentDate == baseDate)
                    .count() > 0

                if alreadySent { skipped += 1; continue }

                guard let score = raster.sample(latitude: poi.latitude, longitude: poi.longitude),
                      score >= threshold else { continue }

                // Fetch the most recent previous notification for this (poi, forecastDate)
                // to detect whether conditions improved or worsened since yesterday.
                let previous = try await POINotification.query(on: db)
                    .filter(\.$poi.$id == poiID)
                    .filter(\.$forecastDate == forecastDate)
                    .filter(\.$sentDate != baseDate)
                    .sort(\.$sentAt, .descending)
                    .first()

                let trend = computeTrend(current: score, previous: previous?.score)

                do {
                    try await apns.send(
                        to: deviceToken,
                        title: notificationTitle(poi: poi.name, score: score),
                        body: notificationBody(
                            dayOffset: dayOffset,
                            forecastDate: forecastDate,
                            score: score,
                            trend: trend
                        ),
                        data: [
                            "type": "forecast",
                            "poi_id": poiID.uuidString,
                            "forecast_date": forecastDate,
                            "score": "\(Int((score * 100).rounded()))",
                            "trend": trend.rawValue
                        ]
                    )
                    let record = POINotification(
                        poiID: poiID,
                        forecastDate: forecastDate,
                        sentDate: baseDate,
                        score: score
                    )
                    try await record.save(on: db)
                    sent += 1
                    logger.info("Notification sent", metadata: [
                        "poi": "\(poi.name)",
                        "date": "\(forecastDate)",
                        "score": "\(Int((score * 100).rounded()))",
                        "trend": "\(trend.rawValue)"
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

    // MARK: - Trend

    enum Trend: String {
        case improving, worsening, stable, firstTime
    }

    private static func computeTrend(current: Double, previous: Double?) -> Trend {
        guard let previous else { return .firstTime }
        let delta = current - previous
        if delta >= trendThreshold { return .improving }
        if delta <= -trendThreshold { return .worsening }
        return .stable
    }

    // MARK: - Messages

    private static func notificationTitle(poi: String, score: Double) -> String {
        let intensity: String
        switch score {
        case 0.85...: intensity = "🍄🍄🍄"
        case 0.65...: intensity = "🍄🍄"
        default:      intensity = "🍄"
        }
        return "\(intensity) \(poi)"
    }

    private static func notificationBody(
        dayOffset: Int,
        forecastDate: String,
        score: Double,
        trend: Trend
    ) -> String {
        let quality: String
        switch score {
        case 0.85...: quality = "condizioni eccellenti"
        case 0.65...: quality = "ottime condizioni"
        default:      quality = "buone condizioni"
        }

        let trendSuffix: String
        switch trend {
        case .improving:  trendSuffix = " Le previsioni sono migliorate rispetto a ieri."
        case .worsening:  trendSuffix = " Le previsioni sono leggermente calate, ma vale ancora la pena."
        case .stable, .firstTime: trendSuffix = ""
        }

        let dayLabel: String
        switch dayOffset {
        case 1: dayLabel = "Domani"
        case 2: dayLabel = "Dopodomani"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            let display = DateFormatter()
            display.locale = Locale(identifier: "it_IT")
            display.dateFormat = "d MMMM"
            display.timeZone = TimeZone(identifier: "Europe/Rome")
            dayLabel = fmt.date(from: forecastDate).map { display.string(from: $0) } ?? forecastDate
        }

        return "\(dayLabel) \(quality) nella tua zona.\(trendSuffix)"
    }
}
