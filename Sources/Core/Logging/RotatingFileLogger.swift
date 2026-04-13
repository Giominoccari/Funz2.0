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
/// @unchecked Sendable: all mutable state is protected by a serial DispatchQueue.
final class RotatingFileWriter: @unchecked Sendable {
    // Serial queue — replaces NSLock to avoid swift-corelibs-foundation NSObject init
    // issues on Linux with Swift 6.0.
    private let queue: DispatchQueue
    private let logsDir: URL
    private let basename: String
    private let maxBytes: Int
    private let maxArchives: Int
    private let filePath: String      // plain String path avoids URL->path bridging in hot path

    private var fd: Int32 = -1        // POSIX file descriptor; avoids FileHandle on Linux
    private var currentBytes: Int = 0

    init(logsDir: URL, basename: String, maxBytes: Int = 10 * 1024 * 1024, maxArchives: Int = 10) throws {
        self.queue     = DispatchQueue(label: "funghi.logwriter.\(basename)")
        self.logsDir   = logsDir
        self.basename  = basename
        self.maxBytes  = maxBytes
        self.maxArchives = maxArchives
        self.filePath  = logsDir.appendingPathComponent("\(basename).log").path
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try openFDUnsafe()
    }

    // Call only from `queue`.
    private func openFDUnsafe() throws {
        closeFDUnsafe()
        // O_WRONLY | O_CREAT | O_APPEND: creates if absent, always writes at end.
        // Avoids FileHandle(forWritingTo:) + seekToEndOfFile() which have
        // known issues in swift-corelibs-foundation on Linux (Swift 6.0).
        #if canImport(Glibc)
        let newFD = Glibc.open(filePath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        #else
        let newFD = Darwin.open(filePath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        #endif
        guard newFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "open(\(filePath)) failed"])
        }
        fd = newFD
        // Current size = position at EOF (O_APPEND already sought there on open).
        #if canImport(Glibc)
        let size = Glibc.lseek(fd, 0, SEEK_END)
        #else
        let size = Darwin.lseek(fd, 0, SEEK_END)
        #endif
        currentBytes = size >= 0 ? Int(size) : 0
    }

    // Call only from `queue`.
    private func closeFDUnsafe() {
        if fd >= 0 {
            #if canImport(Glibc)
            Glibc.close(fd)
            #else
            Darwin.close(fd)
            #endif
            fd = -1
        }
    }

    func write(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        queue.sync {
            guard fd >= 0 else { return }
            #if canImport(Glibc)
            let written = Glibc.write(fd, bytes, bytes.count)
            #else
            let written = Darwin.write(fd, bytes, bytes.count)
            #endif
            if written > 0 { currentBytes += written }
            if currentBytes >= maxBytes { rotateUnsafe() }
        }
    }

    // Call only from `queue`.
    private func rotateUnsafe() {
        closeFDUnsafe()
        let ts = currentTimestampForFilename()
        let archivePath = logsDir.appendingPathComponent("\(basename)-\(ts).log").path
        try? FileManager.default.moveItem(atPath: filePath, toPath: archivePath)
        pruneArchivesUnsafe()
        try? openFDUnsafe()
    }

    // Call only from `queue`.
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
        queue.sync { closeFDUnsafe() }
    }
}

// MARK: - Log handler

/// Custom LogHandler that:
/// - Echoes every record to stdout (Docker captures it as before).
/// - Writes a timestamped line to the appropriate rotating file.
struct FunghiLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level {
        didSet { streamHandler.logLevel = logLevel }
    }

    private let label: String
    private let writer: RotatingFileWriter
    private var streamHandler: StreamLogHandler

    init(label: String, writer: RotatingFileWriter, logLevel: Logger.Level) {
        self.label = label
        self.writer = writer
        self.logLevel = logLevel
        // Pass metadataProvider: nil explicitly — avoids evaluating
        // LoggingSystem.metadataProvider while the bootstrap lock may be held
        // (swift-log 1.6 deadlock/crash on Linux).
        var sh = StreamLogHandler.standardOutput(label: label, metadataProvider: nil)
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
    /// Bootstraps swift-log. Attempts to write rotating files under `logsDir`;
    /// if the directory is inaccessible (bad mount, permission error, etc.) falls
    /// back silently to stdout-only — the server never crashes due to logging setup.
    static func bootstrapFunghi(logsDir: URL, env: Environment) {
        let level: Logger.Level
        if let raw = Environment.get("LOG_LEVEL"), let l = Logger.Level(rawValue: raw) {
            level = l
        } else {
            level = env.isRelease ? .info : .debug
        }

        // try? — a bad mount point must not bring down the API server.
        let pool = try? LogWriterPool(logsDir: logsDir)

        LoggingSystem.bootstrap { label in
            guard let pool else {
                var handler = StreamLogHandler.standardOutput(label: label, metadataProvider: nil)
                handler.logLevel = level
                return handler
            }
            return FunghiLogHandler(label: label, writer: pool.writer(for: label), logLevel: level)
        }

        if pool == nil {
            // Bootstrap is now live — we can use a Logger to report the fallback.
            var logger = Logger(label: "funghi.boot")
            logger.warning("File logging unavailable at \(logsDir.path) — stdout only")
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
