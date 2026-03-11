import Foundation
import Logging
import SotoS3

protocol TileUploader: Sendable {
    func upload(tiles: [GeneratedTile], date: String) async throws
}

struct S3TileUploader: TileUploader {
    private static let logger = Logger(label: "funghi.pipeline.s3")

    let s3: S3
    let bucket: String
    let uploadBatchSize: Int

    init(s3: S3, bucket: String, uploadBatchSize: Int = 50) {
        self.s3 = s3
        self.bucket = bucket
        self.uploadBatchSize = uploadBatchSize
    }

    func upload(tiles: [GeneratedTile], date: String) async throws {
        let phaseStart = ContinuousClock.now
        var uploaded = 0

        for batchStart in stride(from: 0, to: tiles.count, by: uploadBatchSize) {
            let batchEnd = min(batchStart + uploadBatchSize, tiles.count)
            let batch = tiles[batchStart..<batchEnd]

            try await withThrowingTaskGroup(of: Void.self) { group in
                for tile in batch {
                    group.addTask {
                        let key = "\(date)/\(tile.z)/\(tile.x)/\(tile.y).png"
                        let request = S3.PutObjectRequest(
                            body: .init(bytes: tile.pngData),
                            bucket: bucket,
                            contentType: "image/png",
                            key: key
                        )
                        _ = try await s3.putObject(request)
                    }
                }
                try await group.waitForAll()
            }

            uploaded += batch.count
            Self.logger.info("Upload batch complete", metadata: [
                "uploaded": "\(uploaded)/\(tiles.count)",
                "duration": "\(ContinuousClock.now - phaseStart)"
            ])
        }

        Self.logger.info("S3 upload complete", metadata: [
            "totalTiles": "\(tiles.count)",
            "bucket": "\(bucket)",
            "date": "\(date)",
            "duration": "\(ContinuousClock.now - phaseStart)"
        ])
    }
}
