import Fluent
import SQLKit

/// Adds `sent_date` (YYYY-MM-DD) to poi_notifications and changes the unique
/// constraint from (poi_id, forecast_date) to (poi_id, forecast_date, sent_date).
/// This allows one notification per POI per forecast date per calendar day,
/// enabling daily re-notification as the forecast date approaches.
struct AddSentDateToPOINotification: AsyncMigration {
    func prepare(on database: Database) async throws {
        let sql = database as! any SQLDatabase

        // Add sent_date, backfilling existing rows with today (Rome timezone).
        try await sql.raw("""
            ALTER TABLE poi_notifications
            ADD COLUMN IF NOT EXISTS sent_date TEXT NOT NULL
            DEFAULT to_char(NOW() AT TIME ZONE 'Europe/Rome', 'YYYY-MM-DD')
            """).run()

        // Drop the old unique constraint.
        try await sql.raw("""
            ALTER TABLE poi_notifications
            DROP CONSTRAINT IF EXISTS poi_notifications_poi_id_forecast_date_key
            """).run()

        // New unique constraint includes sent_date.
        try await sql.raw("""
            ALTER TABLE poi_notifications
            ADD CONSTRAINT poi_notifications_poi_id_forecast_date_sent_date_key
            UNIQUE (poi_id, forecast_date, sent_date)
            """).run()
    }

    func revert(on database: Database) async throws {
        let sql = database as! any SQLDatabase

        try await sql.raw("""
            ALTER TABLE poi_notifications
            DROP CONSTRAINT IF EXISTS poi_notifications_poi_id_forecast_date_sent_date_key
            """).run()

        try await sql.raw("""
            ALTER TABLE poi_notifications
            ADD CONSTRAINT poi_notifications_poi_id_forecast_date_key
            UNIQUE (poi_id, forecast_date)
            """).run()

        try await sql.raw("""
            ALTER TABLE poi_notifications
            DROP COLUMN IF EXISTS sent_date
            """).run()
    }
}
