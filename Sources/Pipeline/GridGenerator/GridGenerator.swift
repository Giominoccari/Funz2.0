import Foundation
import Logging

struct GridGenerator: Sendable {
    private static let logger = Logger(label: "funghi.pipeline.grid")
    private static let earthRadiusMeters: Double = 6_371_000

    let spacingMeters: Int

    func generate(bbox: BoundingBox) -> [GridPoint] {
        let spacing = Double(spacingMeters)

        // Latitude step: constant everywhere
        let latStep = (spacing / GridGenerator.earthRadiusMeters) * (180.0 / .pi)

        // Longitude step: fixed at bbox centerLat — must match ScoreRaster's formula exactly.
        // ScoreRaster places raster columns at fixed lonStep intervals from centerLat; if
        // GridGenerator used a per-row variable lonStep, points at southern/northern latitudes
        // would land between raster columns, leaving systematic empty columns every ~7-14 cells
        // and causing hasData() to incorrectly skip entire tiles (the visible geometric holes).
        let centerLat = (bbox.minLat + bbox.maxLat) / 2.0
        let lonStep = latStep / cos(centerLat * .pi / 180.0)

        var points: [GridPoint] = []
        var lat = bbox.minLat

        while lat <= bbox.maxLat {
            var lon = bbox.minLon

            while lon <= bbox.maxLon {
                points.append(GridPoint(latitude: lat, longitude: lon))
                lon += lonStep
            }

            lat += latStep
        }

        GridGenerator.logger.info("Grid generated", metadata: [
            "points": "\(points.count)",
            "spacingMeters": "\(spacingMeters)",
            "bbox": "\(bbox.minLat),\(bbox.minLon) → \(bbox.maxLat),\(bbox.maxLon)"
        ])

        return points
    }
}
