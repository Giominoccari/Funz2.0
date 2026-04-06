import Foundation
import Logging
import SQLKit

/// Enriches grid points by querying raster tables in per-table batched SQL calls.
/// Uses 4 separate queries (one per raster layer) instead of a single query with
/// lateral joins, because PostgreSQL's planner drops the GIST index scan when
/// lateral-joining multiple rows against raster tables.
struct BatchGeoEnrichmentClient: Sendable {
    private let db: any SQLDatabase
    private static let logger = Logger(label: "funghi.pipeline.geodata.batch")

    init(db: any SQLDatabase) {
        self.db = db
    }

    /// Enriches a batch of grid points with altitude, forest type, soil type, and aspect.
    /// Runs 4 independent queries (one per raster table) for better query plans.
    /// - Parameter points: Grid points to enrich (recommended batch size: 500–2000)
    /// - Returns: Enriched grid points (same order as input)
    func enrichBatch(_ points: [GridPoint]) async throws -> [GridPoint] {
        guard !points.isEmpty else { return [] }

        var enriched = points

        // Build coordinate arrays once, reused across all 4 queries
        let lons = points.map { "\($0.longitude)" }.joined(separator: ",")
        let lats = points.map { "\($0.latitude)" }.joined(separator: ",")
        let idxs = points.indices.map { "\($0)" }.joined(separator: ",")

        // Run all 4 raster lookups concurrently
        async let altitudes = queryRaster(
            table: "copernicus_dem", cast: "double precision",
            lons: lons, lats: lats, idxs: idxs, count: points.count
        )
        async let corines = queryRaster(
            table: "corine_landcover", cast: "integer",
            lons: lons, lats: lats, idxs: idxs, count: points.count
        )
        async let soils = queryRaster(
            table: "esdac_soil", cast: "integer",
            lons: lons, lats: lats, idxs: idxs, count: points.count
        )
        async let aspects = queryRaster(
            table: "dem_aspect", cast: "double precision",
            lons: lons, lats: lats, idxs: idxs, count: points.count
        )

        let (altRows, corineRows, soilRows, aspectRows) = try await (
            altitudes, corines, soils, aspects
        )

        // Apply altitude
        for row in altRows {
            guard let idx = try? row.decode(column: "idx", as: Int.self),
                  let val = try? row.decode(column: "val", as: Double.self),
                  idx >= 0, idx < enriched.count else { continue }
            enriched[idx].altitude = val
        }

        // Apply forest type (CORINE) + store raw code for habitat filtering
        for row in corineRows {
            guard let idx = try? row.decode(column: "idx", as: Int.self),
                  let val = try? row.decode(column: "val", as: Int.self),
                  idx >= 0, idx < enriched.count else { continue }
            enriched[idx].forestType = PostGISForestClient.mapCORINEToForestType(val)
            enriched[idx].corineCode = val
        }

        // Apply soil type
        for row in soilRows {
            guard let idx = try? row.decode(column: "idx", as: Int.self),
                  let val = try? row.decode(column: "val", as: Int.self),
                  idx >= 0, idx < enriched.count else { continue }
            enriched[idx].soilType = PostGISForestClient.mapESDACSoilType(val)
        }

        // Apply aspect
        for row in aspectRows {
            guard let idx = try? row.decode(column: "idx", as: Int.self),
                  let val = try? row.decode(column: "val", as: Double.self),
                  idx >= 0, idx < enriched.count else { continue }
            enriched[idx].aspect = val
        }

        return enriched
    }

    /// Filters grid points to those within the Italian national boundary.
    ///
    /// Runs a single PostGIS `ST_Within` query against the `italy_boundary` table
    /// (populated by `import-geodata.py`). Called once per pipeline run before geo
    /// enrichment to avoid wasting raster queries on non-Italian territory.
    ///
    /// - Parameter points: All grid points generated from the bounding box.
    /// - Returns: Only the points that fall within the Italian border.
    func filterToItaly(_ points: [GridPoint]) async throws -> [GridPoint] {
        guard !points.isEmpty else { return [] }

        let lons = points.map { "\($0.longitude)" }.joined(separator: ",")
        let lats = points.map { "\($0.latitude)" }.joined(separator: ",")
        let idxs = points.indices.map { "\($0)" }.joined(separator: ",")

        let sql = """
            SELECT p.idx
            FROM (
                SELECT
                    unnest(ARRAY[\(idxs)]) AS idx,
                    ST_SetSRID(ST_MakePoint(
                        unnest(ARRAY[\(lons)]),
                        unnest(ARRAY[\(lats)])
                    ), 4326) AS geom
            ) p
            WHERE ST_Within(p.geom, (SELECT geom FROM italy_boundary LIMIT 1))
            ORDER BY p.idx
            """

        let rows = try await db.raw(SQLQueryString(sql)).all()
        let insideIndices = Set(rows.compactMap { try? $0.decode(column: "idx", as: Int.self) })

        return points.indices.compactMap { insideIndices.contains($0) ? points[$0] : nil }
    }

    /// Queries a single raster table for a batch of points.
    /// Uses UNNEST arrays + a simple subquery so PostgreSQL uses the GIST index.
    private func queryRaster(
        table: String,
        cast: String,
        lons: String,
        lats: String,
        idxs: String,
        count: Int
    ) async throws -> [any SQLRow] {
        let sql = """
            SELECT DISTINCT ON (p.idx)
                p.idx,
                ST_Value(r.rast, p.geom)::\(cast) AS val
            FROM (
                SELECT
                    unnest(ARRAY[\(idxs)]) AS idx,
                    ST_SetSRID(ST_MakePoint(
                        unnest(ARRAY[\(lons)]),
                        unnest(ARRAY[\(lats)])
                    ), 4326) AS geom
            ) p
            JOIN \(table) r ON ST_Intersects(r.rast, p.geom)
            WHERE ST_Value(r.rast, p.geom) IS NOT NULL
            ORDER BY p.idx
            """

        return try await db.raw(SQLQueryString(sql)).all()
    }
}
