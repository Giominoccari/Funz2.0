import Fluent
import SQLKit

struct CreateRasterExtensions: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("CreateRasterExtensions requires a SQL database")
        }
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS postgis").run()
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS postgis_raster").run()
    }

    func revert(on database: Database) async throws {
        // Do not drop extensions on revert — other tables may depend on them
    }
}
