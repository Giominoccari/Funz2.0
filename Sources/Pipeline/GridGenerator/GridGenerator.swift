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

        var points: [GridPoint] = []
        var lat = bbox.minLat

        while lat <= bbox.maxLat {
            // Longitude step: varies with latitude (wider at equator, narrower at poles)
            let lonStep = latStep / cos(lat * .pi / 180.0)
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
