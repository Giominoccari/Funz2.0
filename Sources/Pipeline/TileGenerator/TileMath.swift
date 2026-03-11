import Foundation

enum TileMath {
    static let tileSize = 256

    // MARK: - Coordinate → Tile

    static func tileX(longitude: Double, zoom: Int) -> Int {
        let n = pow(2.0, Double(zoom))
        return Int(floor((longitude + 180.0) / 360.0 * n))
    }

    static func tileY(latitude: Double, zoom: Int) -> Int {
        let n = pow(2.0, Double(zoom))
        let latRad = latitude * .pi / 180.0
        return Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))
    }

    // MARK: - Tile → Bounding Box (WGS84)

    struct TileBounds: Sendable {
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double
    }

    static func tileBounds(x: Int, y: Int, z: Int) -> TileBounds {
        let n = pow(2.0, Double(z))
        let minLon = Double(x) / n * 360.0 - 180.0
        let maxLon = Double(x + 1) / n * 360.0 - 180.0
        let maxLat = atan(sinh(.pi * (1.0 - 2.0 * Double(y) / n))) * 180.0 / .pi
        let minLat = atan(sinh(.pi * (1.0 - 2.0 * Double(y + 1) / n))) * 180.0 / .pi
        return TileBounds(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
    }

    // MARK: - BBox → Tile Coordinates

    struct TileCoord: Sendable, Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    static func tilesForBBox(_ bbox: BoundingBox, zoom: Int) -> [TileCoord] {
        let minX = tileX(longitude: bbox.minLon, zoom: zoom)
        let maxX = tileX(longitude: bbox.maxLon, zoom: zoom)
        let minY = tileY(latitude: bbox.maxLat, zoom: zoom)  // note: Y is inverted
        let maxY = tileY(latitude: bbox.minLat, zoom: zoom)

        var tiles: [TileCoord] = []
        tiles.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for tx in minX...maxX {
            for ty in minY...maxY {
                tiles.append(TileCoord(x: tx, y: ty, z: zoom))
            }
        }
        return tiles
    }

    // MARK: - Pixel → WGS84

    static func pixelToLatLon(
        pixelX: Int, pixelY: Int,
        tileX: Int, tileY: Int, zoom: Int
    ) -> (latitude: Double, longitude: Double) {
        let n = pow(2.0, Double(zoom))
        let lon = (Double(tileX) + Double(pixelX) / Double(tileSize)) / n * 360.0 - 180.0
        let latRad = atan(sinh(.pi * (1.0 - 2.0 * (Double(tileY) + Double(pixelY) / Double(tileSize)) / n)))
        let lat = latRad * 180.0 / .pi
        return (latitude: lat, longitude: lon)
    }
}
