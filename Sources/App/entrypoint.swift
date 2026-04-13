import Foundation
import Logging
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()

        let workDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let logsDir = workDir.appendingPathComponent("Storage/logs")
        do {
            try LoggingSystem.bootstrapFunghi(logsDir: logsDir, env: env)
        } catch {
            // Print directly to stderr — docker logs captures this even before Vapor boots.
            FileHandle.standardError.write(Data("WARNING: file logger init failed: \(error) — stdout only\n".utf8))
            try LoggingSystem.bootstrap(from: &env)
        }

        let app = try await Application.make(env)
        defer { Task { try await app.asyncShutdown() } }

        try await configure(app)
        try await app.execute()
    }
}
