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

    struct Output: Sendable {
        let tiles: [GeneratedTile]
        let raster: ScoreRaster
    }

    func generateAll(
        results: [ScoringEngine.Result],
        bbox: BoundingBox
    ) async -> Output {
        let phaseStart = ContinuousClock.now
        let raster = ScoreRaster(results: results, bbox: bbox)

        // Compute actual score range for dynamic colormap stretching
        let scores = results.map(\.score).filter { $0 > 0.001 }
        let scoreRange: (min: Double, max: Double)? = scores.isEmpty ? nil : (
            min: scores.min()!,
            max: scores.max()!
        )
        Self.logger.info("Score range for colormap", metadata: [
            "min": "\(scoreRange?.min ?? 0)",
            "max": "\(scoreRange?.max ?? 0)",
            "nonZeroPoints": "\(scores.count)",
            "rasterSize": "\(raster.width)x\(raster.height)"
        ])

        var allTiles: [GeneratedTile] = []

        for zoom in tileZoomMin...tileZoomMax {
            let zoomStart = ContinuousClock.now
            let tileCoords = TileMath.tilesForBBox(bbox, zoom: zoom)

            // Render tiles concurrently within each zoom level
            let zoomTiles = await withTaskGroup(
                of: GeneratedTile?.self,
                returning: [GeneratedTile].self
            ) { group in
                for coord in tileCoords {
                    group.addTask {
                        // Early skip: check if tile bbox has any score data
                        let bounds = TileMath.tileBounds(x: coord.x, y: coord.y, z: coord.z)
                        guard raster.hasData(
                            minLat: bounds.minLat, maxLat: bounds.maxLat,
                            minLon: bounds.minLon, maxLon: bounds.maxLon
                        ) else { return nil }

                        return renderTile(coord: coord, raster: raster, scoreRange: scoreRange)
                    }
                }

                var tiles: [GeneratedTile] = []
                tiles.reserveCapacity(tileCoords.count)
                for await tile in group {
                    if let tile { tiles.append(tile) }
                }
                return tiles
            }

            allTiles.append(contentsOf: zoomTiles)

            Self.logger.info("Zoom \(zoom) complete", metadata: [
                "tiles": "\(zoomTiles.count)/\(tileCoords.count)",
                "duration": "\(ContinuousClock.now - zoomStart)"
            ])
        }

        Self.logger.info("Tile generation complete", metadata: [
            "totalTiles": "\(allTiles.count)",
            "zoomRange": "\(tileZoomMin)-\(tileZoomMax)",
            "duration": "\(ContinuousClock.now - phaseStart)"
        ])

        return Output(tiles: allTiles, raster: raster)
    }

    private func renderTile(
        coord: TileMath.TileCoord,
        raster: ScoreRaster,
        scoreRange: (min: Double, max: Double)?
    ) -> GeneratedTile? {
        let size = TileMath.tileSize
        var pixels = [PNG.RGBA<UInt8>](repeating: .init(0, 0, 0, 0), count: size * size)
        var hasData = false

        for py in 0..<size {
            for px in 0..<size {
                let (lat, lon) = TileMath.pixelToLatLon(
                    pixelX: px, pixelY: py,
                    tileX: coord.x, tileY: coord.y, zoom: coord.z
                )

                if let score = raster.sample(latitude: lat, longitude: lon) {
                    let color = Colormap.color(for: score, scoreRange: scoreRange)
                    pixels[py * size + px] = .init(color.r, color.g, color.b, color.a)
                    if color.a > 0 { hasData = true }
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
            // Level 1 (fast) instead of 6 (default) — tiles are small overlay PNGs,
            // compression savings at level 6 are negligible vs. the CPU cost
            try image.compress(stream: &data, level: 1)
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
