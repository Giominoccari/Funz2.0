import Fluent
import SQLKit

struct AddSoilTempColumn: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("AddSoilTempColumn requires a SQL database")
        }

        // Add soil_temp_c column to partitioned weather_observations table.
        // Nullable so existing rows are unaffected; reads use COALESCE fallback.
        try await sql.raw("""
            ALTER TABLE weather_observations
            ADD COLUMN IF NOT EXISTS soil_temp_c REAL
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            ALTER TABLE weather_observations
            DROP COLUMN IF EXISTS soil_temp_c
            """).run()
    }
}
