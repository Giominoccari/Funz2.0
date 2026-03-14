import Foundation
import Logging
import SotoS3
import Vapor

struct MapController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.map")

    func boot(routes: RoutesBuilder) throws {
        let map = routes.grouped("map")
        map.get("tiles", ":date", ":z", ":x", ":y", use: getTile)
        map.get("dates", use: getDates)
    }

    // MARK: - GET /map/tiles/:date/:z/:x/:y

    @Sendable
    func getTile(req: Request) async throws -> Response {
        guard let date = req.parameters.get("date"),
              let zStr = req.parameters.get("z"), let z = Int(zStr),
              let xStr = req.parameters.get("x"), let x = Int(xStr),
              let yStr = req.parameters.get("y"), let y = Int(yStr)
        else {
            throw Abort(.badRequest, reason: "Invalid tile parameters")
        }

        // Validate zoom range
        guard (6...12).contains(z) else {
            throw Abort(.badRequest, reason: "Zoom must be between 6 and 12")
        }

        // 1. Try local directory first
        let localPath = req.application.directory.workingDirectory + "Storage/tiles/\(date)/\(z)/\(x)/\(y).png"

        if FileManager.default.fileExists(atPath: localPath) {
            Self.logger.trace("Serving tile from local storage", metadata: [
                "path": "\(date)/\(z)/\(x)/\(y).png"
            ])
            return try await req.fileio.asyncStreamFile(at: localPath)
        }

        // 2. Fallback to S3 presigned URL redirect
        if let s3Config = self.loadS3Config(req: req) {
            let key = "\(date)/\(z)/\(x)/\(y).png"
            let signedURL = try await self.presignedS3URL(
                bucket: s3Config.bucket,
                key: key,
                region: s3Config.region,
                req: req
            )
            Self.logger.trace("Redirecting to S3", metadata: ["key": "\(key)"])
            return req.redirect(to: signedURL, redirectType: .temporary)
        }

        // 3. Neither local nor S3 available
        throw Abort(.notFound, reason: "Tile not found")
    }

    // MARK: - GET /map/dates

    @Sendable
    func getDates(req: Request) async throws -> [String] {
        let tilesDir = req.application.directory.workingDirectory + "Storage/tiles"

        guard FileManager.default.fileExists(atPath: tilesDir) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: tilesDir)

        // Filter to valid date-like directories (YYYY-MM-DD format)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return contents
            .filter { dateFormatter.date(from: $0) != nil }
            .sorted()
            .reversed()
            .map { $0 }
    }

    // MARK: - S3 Helpers

    private struct S3Info: Sendable {
        let bucket: String
        let region: String
    }

    private func loadS3Config(req: Request) -> S3Info? {
        guard let config = try? ConfigLoader.load() else { return nil }
        // Only use S3 if AWS credentials are available in environment
        guard Environment.get("AWS_ACCESS_KEY_ID") != nil || Environment.get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") != nil else {
            return nil
        }
        return S3Info(bucket: config.s3.tileBucket, region: config.s3.region)
    }

    private func presignedS3URL(bucket: String, key: String, region: String, req: Request) async throws -> String {
        let client = AWSClient()
        let s3 = S3(client: client, region: .init(rawValue: region))
        let url = try await s3.signURL(
            url: URL(string: "https://\(bucket).s3.\(region).amazonaws.com/\(key)")!,
            httpMethod: .GET,
            expires: .seconds(3600)
        )
        try await client.shutdown()
        return url.absoluteString
    }
}
