import Foundation

/// Writes raw Open-Meteo JSON responses to per-date files under `Storage/logs/openmeteo/{date}/`.
/// Each successful batch response gets its own file, named by type, sequential index, and
/// first-coordinate location so responses are individually inspectable with any JSON tool.
///
/// File naming: `historical_001_45.20_9.40.json` / `forecast_001_45.20_9.40.json`
/// File content: raw JSON body exactly as received from Open-Meteo API.
///
/// actor guarantees thread-safe counter increments even when batches complete concurrently.
actor OpenMeteoResponseLogger {
    private let dir: String
    private var historicalCounter: Int = 0
    private var forecastCounter: Int = 0

    /// - Parameters:
    ///   - date: The pipeline target date ("YYYY-MM-DD"), used as a subdirectory.
    ///   - baseDir: Root under which `{date}/` is created. Defaults to `Storage/logs/openmeteo`.
    init(date: String, baseDir: String = "Storage/logs/openmeteo") {
        self.dir = "\(baseDir)/\(date)"
        try? FileManager.default.createDirectory(atPath: self.dir, withIntermediateDirectories: true)
    }

    /// Log a raw historical batch response.
    func logHistorical(firstLat: Double, firstLon: Double, data: Data) {
        historicalCounter += 1
        write(kind: "historical", index: historicalCounter, firstLat: firstLat, firstLon: firstLon, data: data)
    }

    /// Log a raw forecast batch response.
    func logForecast(firstLat: Double, firstLon: Double, data: Data) {
        forecastCounter += 1
        write(kind: "forecast", index: forecastCounter, firstLat: firstLat, firstLon: firstLon, data: data)
    }

    private func write(kind: String, index: Int, firstLat: Double, firstLon: Double, data: Data) {
        let idx = String(format: "%03d", index)
        let loc = String(format: "%.2f_%.2f", firstLat, firstLon)
        let filename = "\(dir)/\(kind)_\(idx)_\(loc).json"
        try? data.write(to: URL(fileURLWithPath: filename))
    }
}
