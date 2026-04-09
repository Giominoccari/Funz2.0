import Foundation
import Logging
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()

        // Rotating file logs under Storage/logs/ (pipeline.log, api.log, app.log).
        // Falls back to Vapor's default stdout-only handler if the directory can't be created.
        let logsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Storage/logs")
        do {
            try LoggingSystem.bootstrapFunghi(logsDir: logsDir, env: env)
        } catch {
            try LoggingSystem.bootstrap(from: &env)
            Logger(label: "funghi.boot").warning("Could not initialise file logging, using stdout only",
                                                  metadata: ["error": "\(error)"])
        }

        let app = try await Application.make(env)
        defer { Task { try await app.asyncShutdown() } }

        try await configure(app)
        try await app.execute()
    }
}
