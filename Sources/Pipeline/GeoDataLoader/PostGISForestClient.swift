import Foundation
import FluentPostgresDriver
import Logging
import SQLKit

struct PostGISForestClient: ForestCoverageClient {
    private let db: any SQLDatabase
    private static let logger = Logger(label: "funghi.pipeline.geodata.postgis")

    init(db: any SQLDatabase) {
        self.db = db
    }

    func forestType(latitude: Double, longitude: Double) async throws -> ForestType {
        let rows = try await db.raw("""
            SELECT ST_Value(rast, ST_SetSRID(ST_MakePoint(\(bind: longitude), \(bind: latitude)), 4326))::integer AS val
            FROM corine_landcover
            WHERE ST_Intersects(rast, ST_SetSRID(ST_MakePoint(\(bind: longitude), \(bind: latitude)), 4326))
            LIMIT 1
            """).all()

        guard let row = rows.first else {
            return .none
        }
        guard let clcCode = try? row.decode(column: "val", as: Int.self) else {
            return .none
        }

        return Self.mapCORINEToForestType(clcCode)
    }

    func soilType(latitude: Double, longitude: Double) async throws -> SoilType {
        let rows = try await db.raw("""
            SELECT ST_Value(rast, ST_SetSRID(ST_MakePoint(\(bind: longitude), \(bind: latitude)), 4326))::integer AS val
            FROM esdac_soil
            WHERE ST_Intersects(rast, ST_SetSRID(ST_MakePoint(\(bind: longitude), \(bind: latitude)), 4326))
            LIMIT 1
            """).all()

        guard let row = rows.first else {
            return .other
        }
        guard let soilCode = try? row.decode(column: "val", as: Int.self) else {
            return .other
        }

        return Self.mapESDACSoilType(soilCode)
    }

    /// Maps CORINE Land Cover (CLC) classification codes to ForestType
    /// Reference: https://land.copernicus.eu/en/products/corine-land-cover
    static func mapCORINEToForestType(_ code: Int) -> ForestType {
        switch code {
        case 311: return .broadleaf
        case 312: return .coniferous
        case 313: return .mixed
        default: return .none
        }
    }

    /// Maps soil classification codes to SoilType.
    /// Supports both ISRIC SoilGrids WRB reference group codes (primary source,
    /// automated download) and legacy ESDAC texture codes (1-3).
    ///
    /// WRB reference groups relevant to fungi substrate:
    /// - Calcareous (alkaline, CaCO3-rich): Calcisol(6), Chernozem(8), Kastanozem(16), Leptosol(17)
    /// - Siliceous (acidic, SiO2-rich): Podzol(24), Arenosol(5), Acrisol(1), Ferralsol(11)
    /// - Mixed (intermediate): Cambisol(7), Luvisol(19), Fluvisol(12), Phaeozem(21), Umbrisol(29)
    static func mapESDACSoilType(_ code: Int) -> SoilType {
        switch code {
        // Legacy ESDAC texture codes (if using manually downloaded ESDAC data)
        case 1: return .calcareous
        case 2: return .siliceous
        case 3: return .mixed
        // WRB reference groups — calcareous (alkaline substrates)
        case 6, 8, 14, 16, 17, 26, 27: return .calcareous
        // WRB reference groups — siliceous (acidic substrates)
        case 5, 11, 18, 20, 23, 24: return .siliceous
        // WRB reference groups — mixed (intermediate substrates)
        case 4, 7, 9, 10, 12, 13, 15, 19, 21, 22, 25, 28, 29, 30: return .mixed
        default: return .other
        }
    }
}
