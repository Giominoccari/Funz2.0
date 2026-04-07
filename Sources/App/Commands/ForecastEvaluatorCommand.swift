import Foundation
import Vapor

/// CLI entry point for forecast evaluation. Core logic lives in ForecastEvaluator.
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

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let baseDate = signature.baseDate ?? Self.todayString()

        try await ForecastEvaluator.run(
            db: app.db,
            httpClient: app.http.client.shared,
            baseDate: baseDate,
            days: signature.days ?? 5,
            threshold: Double(signature.threshold ?? 45) / 100.0
        )
    }

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "Europe/Rome")
        return fmt.string(from: Date())
    }
}
