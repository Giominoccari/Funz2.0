import Foundation

/// Writes raw Open-Meteo JSON responses to two JSONL files under `Storage/logs/openmeteo/{date}/`.
/// Each response is appended as one line (newline-delimited JSON) to:
///   - `historical.jsonl` — archive API responses
///   - `forecast.jsonl`   — forecast API responses
///
/// actor guarantees thread-safe file appends even when batches complete concurrently.
actor OpenMeteoResponseLogger {
    private let historicalURL: URL
    private let forecastURL: URL

    /// - Parameters:
    ///   - date: The pipeline target date ("YYYY-MM-DD"), used as a subdirectory.
    ///   - baseDir: Root under which `{date}/` is created. Defaults to `Storage/logs/openmeteo`.
    init(date: String, baseDir: String = "Storage/logs/openmeteo") {
        let dir = "\(baseDir)/\(date)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.historicalURL = URL(fileURLWithPath: "\(dir)/historical.jsonl")
        self.forecastURL = URL(fileURLWithPath: "\(dir)/forecast.jsonl")
    }

    /// Append a raw historical batch response as one line.
    func logHistorical(firstLat: Double, firstLon: Double, data: Data) {
        append(data: data, to: historicalURL)
    }

    /// Append a raw forecast batch response as one line.
    func logForecast(firstLat: Double, firstLon: Double, data: Data) {
        append(data: data, to: forecastURL)
    }

    private func append(data: Data, to url: URL) {
        var line = data
        line.append(0x0A) // newline
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: url)
        }
    }
}
