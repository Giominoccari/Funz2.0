import Foundation

final class MockTileUploader: TileUploader, @unchecked Sendable {
    // @unchecked Sendable: test-only mock with mutable state protected by lock
    private let lock = NSLock()
    private var _uploadedPaths: [String] = []
    private var _uploadedTiles: [GeneratedTile] = []

    var uploadedPaths: [String] {
        lock.withLock { _uploadedPaths }
    }

    var uploadedTiles: [GeneratedTile] {
        lock.withLock { _uploadedTiles }
    }

    var uploadCount: Int {
        lock.withLock { _uploadedPaths.count }
    }

    func upload(tiles: [GeneratedTile], date: String) async throws {
        lock.withLock {
            for tile in tiles {
                _uploadedPaths.append("\(date)/\(tile.z)/\(tile.x)/\(tile.y).png")
                _uploadedTiles.append(tile)
            }
        }
    }
}
