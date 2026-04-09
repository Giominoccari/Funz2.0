import Foundation
import Logging
import Vapor

// MARK: - Log file categories

private enum LogCategory {
    case pipeline, api, app

    static func categorize(_ label: String) -> LogCategory {
        if label.hasPrefix("funghi.pipeline") || label == "funghi.scheduler"
            || label == "funghi.evaluator" || label == "funghi.worker" || label == "funghi.bench" {
            return .pipeline
        }
        if label.hasPrefix("funghi.map") || label == "funghi.auth" || label == "funghi.user"
            || label == "funghi.subscription" || label == "funghi.stripe" || label == "funghi.poi"
            || label == "funghi.apns" || label == "funghi.weather" || label == "funghi.admin" {
            return .api
        }
        return .app
    }
}

// MARK: - Rotating file writer

/// Thread-safe rotating log writer. Writes to `<basename>.log`; on reaching `maxBytes`
/// renames it to `<basename>-<timestamp>.log` and starts a fresh file.
/// Keeps at most `maxArchives` rotated copies, deleting the oldest first.
///
/// @unchecked Sendable: all mutable state is protected by `lock`.
final class RotatingFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let logsDir: URL
    private let basename: String
    private let maxBytes: Int
    private let maxArchives: Int
    private let fileURL: URL

    private var fileHandle: FileHandle?
    private var currentBytes: Int = 0

    init(logsDir: URL, basename: String, maxBytes: Int = 10 * 1024 * 1024, maxArchives: Int = 10) throws {
        self.logsDir = logsDir
        self.basename = basename
        self.maxBytes = maxBytes
        self.maxArchives = maxArchives
        self.fileURL = logsDir.appendingPathComponent("\(basename).log")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try openHandleUnsafe()
    }

    // Call while holding `lock`.
    private func openHandleUnsafe() throws {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: url)
        fh.seekToEndOfFile()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        currentBytes = (attrs[.size] as? Int) ?? 0
        fileHandle = fh
    }

    func write(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        lock.lock()
        defer { lock.unlock() }
        fileHandle?.write(data)
        currentBytes += data.count
        if currentBytes >= maxBytes {
            rotateUnsafe()
        }
    }

    // Call while holding `lock`.
    private func rotateUnsafe() {
        fileHandle?.closeFile()
        fileHandle = nil

        let ts = currentTimestampForFilename()
        let archiveURL = logsDir.appendingPathComponent("\(basename)-\(ts).log")
        try? FileManager.default.moveItem(at: fileURL, to: archiveURL)
        pruneArchivesUnsafe()
        try? openHandleUnsafe()
    }

    // Call while holding `lock`.
    private func pruneArchivesUnsafe() {
        let prefix = "\(basename)-"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let archives = files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "log" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return d1 < d2
            }

        if archives.count > maxArchives {
            archives.prefix(archives.count - maxArchives).forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }
    }

    deinit {
        lock.lock()
        fileHandle?.closeFile()
        lock.unlock()
    }
}

// MARK: - Log handler

/// Custom LogHandler that:
/// - Echoes every record to stdout (Docker captures it as before).
/// - Writes a timestamped line to the appropriate rotating file.
struct FunghiLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level

    private let label: String
    private let writer: RotatingFileWriter
    private var streamHandler: StreamLogHandler

    init(label: String, writer: RotatingFileWriter, logLevel: Logger.Level) {
        self.label = label
        self.writer = writer
        self.logLevel = logLevel
        var sh = StreamLogHandler.standardOutput(label: label)
        sh.logLevel = logLevel
        self.streamHandler = sh
    }

    mutating func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // Echo to stdout — Docker log driver captures this unchanged.
        streamHandler.log(level: level, message: message, metadata: metadata,
                          source: source, file: file, function: function, line: line)

        // Build file log line with ISO-8601 timestamp.
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        let metaStr = merged.isEmpty ? "" : " " + merged
            .sorted(by: { $0.key < $1.key })
            .map { "[\($0.key): \($0.value)]" }
            .joined(separator: " ")
        let ts = currentTimestamp()
        let lvl = level.rawValue.uppercased().padding(toLength: 8, withPad: " ", startingAt: 0)
        writer.write("\(ts) [\(lvl)] \(label): \(message)\(metaStr)")
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}

// MARK: - Writer pool

/// Holds one writer per log file category. Initialized once in `entrypoint.swift`
/// before `LoggingSystem.bootstrap` and shared via a module-level global.
final class LogWriterPool: @unchecked Sendable {
    let pipeline: RotatingFileWriter
    let api: RotatingFileWriter
    let app: RotatingFileWriter

    init(logsDir: URL) throws {
        pipeline = try RotatingFileWriter(logsDir: logsDir, basename: "pipeline")
        api      = try RotatingFileWriter(logsDir: logsDir, basename: "api")
        app      = try RotatingFileWriter(logsDir: logsDir, basename: "app")
    }

    func writer(for label: String) -> RotatingFileWriter {
        switch LogCategory.categorize(label) {
        case .pipeline: return pipeline
        case .api:      return api
        case .app:      return app
        }
    }
}

// MARK: - Bootstrap helper

extension LoggingSystem {
    /// Bootstraps swift-log with a `FunghiLogHandler` that writes to rotating files
    /// under `logsDir` while echoing every record to stdout.
    static func bootstrapFunghi(logsDir: URL, env: Environment) throws {
        let level: Logger.Level
        if let raw = Environment.get("LOG_LEVEL"), let l = Logger.Level(rawValue: raw) {
            level = l
        } else {
            level = env.isRelease ? .info : .debug
        }

        let pool = try LogWriterPool(logsDir: logsDir)

        LoggingSystem.bootstrap { label in
            FunghiLogHandler(label: label, writer: pool.writer(for: label), logLevel: level)
        }
    }
}

// MARK: - Thread-safe timestamp helpers
//
// Using Calendar/DateComponents rather than C time functions (gettimeofday/gmtime_r)
// to avoid Swift–Glibc interop edge cases on Linux.

private let _utcCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private let _romeCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Rome")!
    return c
}()

/// Thread-safe ISO-8601 log timestamp: "2026-04-09T02:45:23.123Z"
func currentTimestamp() -> String {
    let now = Date()
    let c = _utcCal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
    let ms = (c.nanosecond ?? 0) / 1_000_000
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                  c.year ?? 0, c.month ?? 0, c.day ?? 0,
                  c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
}

/// Timestamp safe for use in filenames (Rome time): "2026-04-09T02-45-23"
func currentTimestampForFilename() -> String {
    let now = Date()
    let c = _romeCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
    return String(format: "%04d-%02d-%02dT%02d-%02d-%02d",
                  c.year ?? 0, c.month ?? 0, c.day ?? 0,
                  c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
}
