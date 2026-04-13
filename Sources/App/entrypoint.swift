import Foundation
import Logging
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()

        let workDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let logsDir = workDir.appendingPathComponent("Storage/logs")
        try LoggingSystem.bootstrapFunghi(logsDir: logsDir, env: env)

        let app = try await Application.make(env)
        defer { Task { try await app.asyncShutdown() } }

        try await configure(app)
        try await app.execute()
    }
}
