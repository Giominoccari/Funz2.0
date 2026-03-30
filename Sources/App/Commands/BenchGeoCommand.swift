import Logging
import SQLKit
import Vapor

/// Benchmarks geo enrichment at increasing batch sizes to find the optimal value.
/// Usage: swift run App bench-geo
struct BenchGeoCommand: AsyncCommand {
    struct Signature: CommandSignature {}

    var help: String {
        "Benchmark geo enrichment SQL queries at different batch sizes."
    }

    private let logger = Logger(label: "funghi.bench")

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let sqlDb = app.db as! any SQLDatabase
        let geoClient = BatchGeoEnrichmentClient(db: sqlDb)

        // Generate a small set of test points in central Italy (Toscana)
        let gridGen = GridGenerator(spacingMeters: 500)
        let testBbox = BoundingBox(minLat: 43.0, maxLat: 43.5, minLon: 11.0, maxLon: 11.5)
        let allPoints = gridGen.generate(bbox: testBbox)

        logger.info("Benchmark grid generated", metadata: [
            "points": "\(allPoints.count)",
            "bbox": "43.0,11.0 → 43.5,11.5"
        ])

        let batchSizes = [1, 10, 50, 100, 200, 300, 500, 750, 1000, 1500, 2000]

        logger.info("Starting benchmark...")

        for size in batchSizes {
            let testPoints = Array(allPoints.prefix(size))

            // Warm up: run once and discard
            _ = try? await geoClient.enrichBatch(Array(allPoints.prefix(min(size, 10))))

            // Measure 3 runs and take the median
            var durations: [Double] = []
            for _ in 0..<3 {
                let start = ContinuousClock.now
                _ = try? await geoClient.enrichBatch(testPoints)
                let elapsed = ContinuousClock.now - start
                let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
                    + Double(elapsed.components.seconds) * 1000.0
                durations.append(ms)
            }
            durations.sort()
            let median = durations[1]
            let perPoint = median / Double(size)

            logger.info("Batch \(size) points", metadata: [
                "medianMs": "\(String(format: "%.1f", median))",
                "perPointMs": "\(String(format: "%.2f", perPoint))",
                "allRunsMs": "\(durations.map { String(format: "%.1f", $0) }.joined(separator: ", "))"
            ])
        }

        // Estimate total pipeline time for 4.6M points at each batch size
        logger.info("--- Estimated total time for 4,599,740 points ---")
        // Re-run to collect fresh numbers for estimation
        for size in [100, 200, 300, 500, 1000] {
            let testPoints = Array(allPoints.prefix(size))
            let start = ContinuousClock.now
            _ = try? await geoClient.enrichBatch(testPoints)
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(elapsed.components.seconds) * 1000.0
            let totalBatches = 4_599_740 / size
            let estimatedMinutes = (ms * Double(totalBatches)) / 60_000.0
            logger.info("batchSize=\(size)", metadata: [
                "queryMs": "\(String(format: "%.1f", ms))",
                "batches": "\(totalBatches)",
                "estimatedMinutes": "\(String(format: "%.0f", estimatedMinutes))"
            ])
        }
    }
}
