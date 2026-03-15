import Foundation
import FluentPostgresDriver
import Logging
import SQLKit

struct PostGISAltitudeClient: AltitudeClient {
    private let db: any SQLDatabase
    private static let logger = Logger(label: "funghi.pipeline.geodata.altitude")

    init(db: any SQLDatabase) {
        self.db = db
    }

    func altitude(latitude: Double, longitude: Double) async throws -> Double {
        let rows = try await db.raw("""
            SELECT ST_Value(rast, ST_SetSRID(ST_MakePoint(\(bind: longitude), \(bind: latitude)), 4326))::double precision AS val
            FROM copernicus_dem
            WHERE ST_Intersects(rast, ST_SetSRID(ST_MakePoint(\(bind: longitude), \(bind: latitude)), 4326))
            LIMIT 1
            """).all()

        guard let row = rows.first,
              let value = try? row.decode(column: "val", as: Double.self) else {
            Self.logger.warning("No DEM data for point", metadata: [
                "lat": "\(latitude)", "lon": "\(longitude)"
            ])
            return 0
        }
        return value
    }

    func aspect(latitude: Double, longitude: Double) async throws -> Double {
        let rows = try await db.raw("""
            SELECT ST_Value(rast, ST_SetSRID(ST_MakePoint(\(bind: longitude), \(bind: latitude)), 4326))::double precision AS val
            FROM dem_aspect
            WHERE ST_Intersects(rast, ST_SetSRID(ST_MakePoint(\(bind: longitude), \(bind: latitude)), 4326))
            LIMIT 1
            """).all()

        guard let row = rows.first,
              let value = try? row.decode(column: "val", as: Double.self) else {
            Self.logger.warning("No aspect data for point", metadata: [
                "lat": "\(latitude)", "lon": "\(longitude)"
            ])
            return 0
        }
        return value
    }
}
