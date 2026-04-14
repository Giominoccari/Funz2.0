import Fluent
import SQLKit

/// Adds `score` (0.0–1.0) to poi_notifications so the evaluator can compare
/// today's forecast score against the previously stored value and detect trends.
struct AddScoreToPOINotification: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! any SQLDatabase
        try await sql.raw("""
            ALTER TABLE poi_notifications
            ADD COLUMN IF NOT EXISTS score DOUBLE PRECISION
            """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! any SQLDatabase
        try await sql.raw("""
            ALTER TABLE poi_notifications
            DROP COLUMN IF EXISTS score
            """).run()
    }
}
