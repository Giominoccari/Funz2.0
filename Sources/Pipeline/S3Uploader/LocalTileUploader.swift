import Foundation
import Logging

struct LocalTileUploader: TileUploader {
    private static let logger = Logger(label: "funghi.pipeline.local")
    private let baseDir: String

    init(baseDir: String = "Storage/tiles") {
        self.baseDir = baseDir
    }

    func upload(tiles: [GeneratedTile], date: String) async throws {
        for tile in tiles {
            let dir = "\(baseDir)/\(date)/\(tile.z)/\(tile.x)"
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
            let path = "\(dir)/\(tile.y).png"
            try Data(tile.pngData).write(to: URL(fileURLWithPath: path))
        }
        Self.logger.info("Tiles written to disk", metadata: [
            "count": "\(tiles.count)",
            "path": "\(baseDir)/\(date)/"
        ])
    }
}
