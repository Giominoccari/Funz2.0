import Fluent
import SQLKit

struct CreateWeatherObservations: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("CreateWeatherObservations requires a SQL database")
        }

        // Partitioned table: one partition per month for efficient date-range queries
        // and instant old-data cleanup (DROP partition vs DELETE millions of rows).
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS weather_observations (
                id              BIGSERIAL,
                latitude        DOUBLE PRECISION NOT NULL,
                longitude       DOUBLE PRECISION NOT NULL,
                observed_date   DATE NOT NULL,
                rain_mm         REAL NOT NULL,
                temp_mean_c     REAL NOT NULL,
                humidity_pct    REAL NOT NULL,
                created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
                PRIMARY KEY (observed_date, id),
                UNIQUE (latitude, longitude, observed_date)
            ) PARTITION BY RANGE (observed_date)
            """).run()

        // Index for nearest-point API lookups (covers all dates in a partition)
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_weather_obs_coords
            ON weather_observations (latitude, longitude)
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS weather_observations CASCADE").run()
    }
}
