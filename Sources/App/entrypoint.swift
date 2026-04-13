import Foundation
import Logging
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()

        // LOG_DIR enables rotating file logging (set on beta, leave unset locally).
        // Without it the app uses stdout only — avoids blocking open() on
        // VirtioFS/iCloud mounts that Colima can't follow.
        if let logDirPath = Environment.get("LOG_DIR"), !logDirPath.isEmpty {
            LoggingSystem.bootstrapFunghi(logsDir: URL(fileURLWithPath: logDirPath), env: env)
        } else {
            try LoggingSystem.bootstrap(from: &env)
        }

        let app = try await Application.make(env)
        defer { Task { try await app.asyncShutdown() } }

        try await configure(app)
        try await app.execute()
    }
}
