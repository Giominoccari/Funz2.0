import Testing
@testable import App

@Suite("TileMath Tests")
struct TileMathTests {

    // MARK: - Coordinate → Tile

    @Test("tileX at zoom 0 returns 0 for any longitude")
    func tileXZoom0() {
        #expect(TileMath.tileX(longitude: 0, zoom: 0) == 0)
        #expect(TileMath.tileX(longitude: 11.3, zoom: 0) == 0)
    }

    @Test("tileX at zoom 8 for Trentino longitude")
    func tileXTrentino() {
        // Trentino ~11.3°E at zoom 8 → tile X = 136
        let x = TileMath.tileX(longitude: 11.3, zoom: 8)
        #expect(x >= 135 && x <= 137)
    }

    @Test("tileY at zoom 8 for Trentino latitude")
    func tileYTrentino() {
        // Trentino ~46.1°N at zoom 8 → tile Y ~ 92
        let y = TileMath.tileY(latitude: 46.1, zoom: 8)
        #expect(y >= 90 && y <= 95)
    }

    // MARK: - Tile Bounds

    @Test("tileBounds roundtrip: coordinate falls within its tile bounds")
    func tileBoundsRoundtrip() {
        let lat = 46.1
        let lon = 11.3
        let zoom = 10
        let x = TileMath.tileX(longitude: lon, zoom: zoom)
        let y = TileMath.tileY(latitude: lat, zoom: zoom)
        let bounds = TileMath.tileBounds(x: x, y: y, z: zoom)
        #expect(lat >= bounds.minLat && lat <= bounds.maxLat)
        #expect(lon >= bounds.minLon && lon <= bounds.maxLon)
    }

    @Test("tileBounds at zoom 0 covers the world")
    func tileBoundsZoom0() {
        let bounds = TileMath.tileBounds(x: 0, y: 0, z: 0)
        #expect(bounds.minLon == -180.0)
        #expect(bounds.maxLon == 180.0)
        #expect(bounds.maxLat > 85.0)
        #expect(bounds.minLat < -85.0)
    }

    // MARK: - BBox → Tiles

    @Test("tilesForBBox at zoom 6 returns small tile count for Trentino")
    func tilesForBBoxZoom6() {
        let tiles = TileMath.tilesForBBox(.trentino, zoom: 6)
        #expect(tiles.count >= 1 && tiles.count <= 4)
    }

    @Test("tilesForBBox at zoom 10 returns moderate count for Trentino")
    func tilesForBBoxZoom10() {
        let tiles = TileMath.tilesForBBox(.trentino, zoom: 10)
        #expect(tiles.count >= 6 && tiles.count <= 30)
    }

    @Test("tilesForBBox tile count grows with zoom level")
    func tileCountGrowsWithZoom() {
        let count8 = TileMath.tilesForBBox(.trentino, zoom: 8).count
        let count10 = TileMath.tilesForBBox(.trentino, zoom: 10).count
        let count12 = TileMath.tilesForBBox(.trentino, zoom: 12).count
        #expect(count10 > count8)
        #expect(count12 > count10)
    }

    // MARK: - Pixel → LatLon

    @Test("pixelToLatLon top-left pixel matches tile bounds")
    func pixelTopLeft() {
        let x = 136
        let y = 92
        let z = 8
        let bounds = TileMath.tileBounds(x: x, y: y, z: z)
        let (lat, lon) = TileMath.pixelToLatLon(pixelX: 0, pixelY: 0, tileX: x, tileY: y, zoom: z)
        #expect(abs(lat - bounds.maxLat) < 0.001)
        #expect(abs(lon - bounds.minLon) < 0.001)
    }

    @Test("pixelToLatLon center pixel is inside tile bounds")
    func pixelCenter() {
        let x = 136
        let y = 92
        let z = 8
        let bounds = TileMath.tileBounds(x: x, y: y, z: z)
        let (lat, lon) = TileMath.pixelToLatLon(pixelX: 128, pixelY: 128, tileX: x, tileY: y, zoom: z)
        #expect(lat > bounds.minLat && lat < bounds.maxLat)
        #expect(lon > bounds.minLon && lon < bounds.maxLon)
    }
}
