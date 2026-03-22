import Foundation
import Logging
import PNG

struct GeneratedTile: Sendable {
    let z: Int
    let x: Int
    let y: Int
    let pngData: [UInt8]
}

struct TileGenerator: Sendable {
    private static let logger = Logger(label: "funghi.pipeline.tiles")

    let tileZoomMin: Int
    let tileZoomMax: Int

    func generateAll(
        results: [ScoringEngine.Result],
        bbox: BoundingBox
    ) -> [GeneratedTile] {
        let phaseStart = ContinuousClock.now
        let interpolator = IDWInterpolator(results: results)

        // Compute actual score range for dynamic colormap stretching
        let scores = results.map(\.score).filter { $0 > 0.001 }
        let scoreRange: (min: Double, max: Double)? = scores.isEmpty ? nil : (
            min: scores.min()!,
            max: scores.max()!
        )
        Self.logger.info("Score range for colormap", metadata: [
            "min": "\(scoreRange?.min ?? 0)",
            "max": "\(scoreRange?.max ?? 0)",
            "nonZeroPoints": "\(scores.count)"
        ])

        var tiles: [GeneratedTile] = []

        for zoom in tileZoomMin...tileZoomMax {
            let zoomStart = ContinuousClock.now
            let tileCoords = TileMath.tilesForBBox(bbox, zoom: zoom)

            for coord in tileCoords {
                if let tile = renderTile(coord: coord, interpolator: interpolator, scoreRange: scoreRange) {
                    tiles.append(tile)
                }
            }

            Self.logger.info("Zoom \(zoom) complete", metadata: [
                "tiles": "\(tileCoords.count)",
                "duration": "\(ContinuousClock.now - zoomStart)"
            ])
        }

        Self.logger.info("Tile generation complete", metadata: [
            "totalTiles": "\(tiles.count)",
            "zoomRange": "\(tileZoomMin)-\(tileZoomMax)",
            "duration": "\(ContinuousClock.now - phaseStart)"
        ])

        return tiles
    }

    private func renderTile(
        coord: TileMath.TileCoord,
        interpolator: IDWInterpolator,
        scoreRange: (min: Double, max: Double)?
    ) -> GeneratedTile? {
        let size = TileMath.tileSize
        var pixels: [PNG.RGBA<UInt8>] = []
        pixels.reserveCapacity(size * size)
        var hasData = false

        for py in 0..<size {
            for px in 0..<size {
                let (lat, lon) = TileMath.pixelToLatLon(
                    pixelX: px, pixelY: py,
                    tileX: coord.x, tileY: coord.y, zoom: coord.z
                )

                if let score = interpolator.interpolate(latitude: lat, longitude: lon) {
                    let color = Colormap.color(for: score, scoreRange: scoreRange)
                    pixels.append(.init(color.r, color.g, color.b, color.a))
                    if color.a > 0 { hasData = true }
                } else {
                    pixels.append(.init(0, 0, 0, 0))
                }
            }
        }

        guard hasData else { return nil }

        guard let pngData = encodePNG(pixels: pixels, width: size, height: size) else {
            Self.logger.error("Failed to encode PNG for tile \(coord.z)/\(coord.x)/\(coord.y)")
            return nil
        }

        return GeneratedTile(z: coord.z, x: coord.x, y: coord.y, pngData: pngData)
    }

    private func encodePNG(pixels: [PNG.RGBA<UInt8>], width: Int, height: Int) -> [UInt8]? {
        let image = PNG.Image(
            packing: pixels,
            size: (x: width, y: height),
            layout: .init(format: .rgba8(palette: [], fill: nil))
        )

        var data: [UInt8] = []
        do {
            try image.compress(stream: &data, level: 6)
            return data
        } catch {
            return nil
        }
    }
}

// MARK: - PNG stream conformance for [UInt8]

extension [UInt8]: @retroactive PNG.BytestreamDestination {
    public mutating func write(_ buffer: [UInt8]) -> Void? {
        self.append(contentsOf: buffer)
        return ()
    }
}
