import Fluent
import SQLKit

/// Creates the `italy_boundary` vector table used to filter grid points to Italian territory.
///
/// Populated by `infra/scripts/import-geodata.py` (italy_boundary section).
/// Data source: Natural Earth 10m Admin 0 Countries — public domain (CC0).
struct CreateItalyBoundary: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("CreateItalyBoundary requires a SQL database")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS italy_boundary (
                id   SERIAL PRIMARY KEY,
                geom GEOMETRY(MultiPolygon, 4326) NOT NULL
            )
            """).run()

        // GIST index — required for ST_Within to use index scan instead of seq scan
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_italy_boundary_geom
            ON italy_boundary USING GIST (geom)
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS italy_boundary CASCADE").run()
    }
}
