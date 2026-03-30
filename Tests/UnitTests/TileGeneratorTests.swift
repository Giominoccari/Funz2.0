import Testing
@testable import App

@Suite("TileGenerator Tests")
struct TileGeneratorTests {

    // MARK: - Colormap

    @Test("Colormap zero score returns transparent")
    func colormapZero() {
        let color = Colormap.color(for: 0.0)
        #expect(color == .transparent)
    }

    @Test("Colormap low score is greenish")
    func colormapLow() {
        let color = Colormap.color(for: 0.2)
        #expect(color.g > color.r)  // green dominant
        #expect(color.a > 0)
    }

    @Test("Colormap mid score is yellowish")
    func colormapMid() {
        let color = Colormap.color(for: 0.5)
        #expect(color.r > 200)
        #expect(color.g > 200)
        #expect(color.b == 0)
    }

    @Test("Colormap high score is reddish")
    func colormapHigh() {
        let color = Colormap.color(for: 1.0)
        #expect(color.r == 255)
        #expect(color.g == 0)
        #expect(color.a > 0)
    }

    @Test("Colormap clamps out-of-range values")
    func colormapClamp() {
        let colorNeg = Colormap.color(for: -0.5)
        #expect(colorNeg == .transparent)

        let colorOver = Colormap.color(for: 1.5)
        #expect(colorOver.r == 255)
        #expect(colorOver.g == 0)
    }

    // MARK: - IDW Interpolator

    @Test("IDW interpolation at exact point returns that score")
    func idwExactPoint() {
        let results = [ScoringEngine.Result(latitude: 46.0, longitude: 11.0, score: 0.75, baseScore: 0.75, weatherScore: 1.0)]
        let idw = IDWInterpolator(results: results)
        let score = idw.interpolate(latitude: 46.0, longitude: 11.0)
        #expect(score != nil)
        #expect(abs(score! - 0.75) < 0.001)
    }

    @Test("IDW interpolation between two equidistant points averages")
    func idwEquidistant() {
        let results = [
            ScoringEngine.Result(latitude: 46.0, longitude: 11.0, score: 0.4, baseScore: 0.4, weatherScore: 1.0),
            ScoringEngine.Result(latitude: 46.0, longitude: 11.01, score: 0.8, baseScore: 0.8, weatherScore: 1.0),
        ]
        let idw = IDWInterpolator(results: results)
        let score = idw.interpolate(latitude: 46.0, longitude: 11.005)
        #expect(score != nil)
        #expect(abs(score! - 0.6) < 0.05)  // should be close to average
    }

    @Test("IDW interpolation returns nil when no nearby data")
    func idwNoData() {
        let results = [ScoringEngine.Result(latitude: 46.0, longitude: 11.0, score: 0.5, baseScore: 0.5, weatherScore: 1.0)]
        let idw = IDWInterpolator(results: results, searchRadius: 0.01)
        let score = idw.interpolate(latitude: 47.0, longitude: 12.0)
        #expect(score == nil)
    }

    // MARK: - TileGenerator

    @Test("generateAll produces tiles for small result set")
    func generateAllProducesTiles() async {
        // Create a small grid of scored points covering Trentino
        var results: [ScoringEngine.Result] = []
        for lat in stride(from: 45.8, through: 46.5, by: 0.05) {
            for lon in stride(from: 10.8, through: 11.8, by: 0.05) {
                let score = 0.3 + 0.4 * (lat - 45.8) / 0.7
                results.append(.init(latitude: lat, longitude: lon, score: score, baseScore: score, weatherScore: 1.0))
            }
        }

        let gen = TileGenerator(tileZoomMin: 6, tileZoomMax: 8)
        let tiles = await gen.generateAll(results: results, bbox: .trentino)

        #expect(tiles.count > 0)
    }

    @Test("Generated tile has valid PNG header")
    func tileHasValidPNG() async {
        var results: [ScoringEngine.Result] = []
        for lat in stride(from: 45.8, through: 46.5, by: 0.05) {
            for lon in stride(from: 10.8, through: 11.8, by: 0.05) {
                results.append(.init(latitude: lat, longitude: lon, score: 0.5, baseScore: 0.5, weatherScore: 1.0))
            }
        }

        let gen = TileGenerator(tileZoomMin: 8, tileZoomMax: 8)
        let tiles = await gen.generateAll(results: results, bbox: .trentino)

        guard let firstTile = tiles.first else {
            Issue.record("No tiles generated")
            return
        }

        // PNG magic bytes: 0x89 0x50 0x4E 0x47
        #expect(firstTile.pngData.count > 8)
        #expect(firstTile.pngData[0] == 0x89)
        #expect(firstTile.pngData[1] == 0x50)  // P
        #expect(firstTile.pngData[2] == 0x4E)  // N
        #expect(firstTile.pngData[3] == 0x47)  // G
    }

    @Test("Generated tile PNG contains IHDR with 256x256")
    func tileIs256x256() async {
        var results: [ScoringEngine.Result] = []
        for lat in stride(from: 45.8, through: 46.5, by: 0.05) {
            for lon in stride(from: 10.8, through: 11.8, by: 0.05) {
                results.append(.init(latitude: lat, longitude: lon, score: 0.6, baseScore: 0.6, weatherScore: 1.0))
            }
        }

        let gen = TileGenerator(tileZoomMin: 8, tileZoomMax: 8)
        let tiles = await gen.generateAll(results: results, bbox: .trentino)

        guard let tile = tiles.first, tile.pngData.count > 24 else {
            Issue.record("No tiles or too small")
            return
        }

        // IHDR chunk starts at byte 8 (after signature)
        // Bytes 8-11: chunk length (should be 13)
        // Bytes 12-15: "IHDR"
        // Bytes 16-19: width (big-endian UInt32)
        // Bytes 20-23: height (big-endian UInt32)
        let width = UInt32(tile.pngData[16]) << 24
            | UInt32(tile.pngData[17]) << 16
            | UInt32(tile.pngData[18]) << 8
            | UInt32(tile.pngData[19])
        let height = UInt32(tile.pngData[20]) << 24
            | UInt32(tile.pngData[21]) << 16
            | UInt32(tile.pngData[22]) << 8
            | UInt32(tile.pngData[23])

        #expect(width == 256)
        #expect(height == 256)
    }

    // MARK: - MockTileUploader

    @Test("MockTileUploader records uploaded paths")
    func mockUploaderRecords() async throws {
        let mock = MockTileUploader()
        let tiles = [
            GeneratedTile(z: 8, x: 136, y: 92, pngData: [0x89, 0x50]),
            GeneratedTile(z: 8, x: 137, y: 92, pngData: [0x89, 0x50]),
        ]

        try await mock.upload(tiles: tiles, date: "2026-03-08")

        #expect(mock.uploadCount == 2)
        #expect(mock.uploadedPaths.contains("2026-03-08/8/136/92.png"))
        #expect(mock.uploadedPaths.contains("2026-03-08/8/137/92.png"))
    }
}
