import Foundation
import Logging
import PNG
import SotoS3
import Vapor

struct MapController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.map")

    func boot(routes: RoutesBuilder) throws {
        let map = routes.grouped("map")
        let protectedMap = map.grouped(JWTAuthMiddleware(), SubscriptionMiddleware())
        // Historical tiles
        protectedMap.get("tiles", ":date", ":z", ":x", ":y", use: getTile)
        protectedMap.get("dynamic-tiles", ":date", ":z", ":x", ":y", use: getDynamicTile)
        // Forecast tiles (served from Storage/tiles/forecast/{date}/)
        protectedMap.get("forecast-tiles", ":date", ":z", ":x", ":y", use: getForecastTile)
        // Dev-only: unauthenticated tile access (local files only, no S3)
        map.get("dev-tiles", ":date", ":z", ":x", ":y", use: getDevTile)
        // Score point lookup
        map.get("score", use: getScore)
        // Dates listings (public)
        map.get("dates", use: getDates)
        map.get("forecast-dates", use: getForecastDates)
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

        // Validate zoom range (absolute bounds)
        guard (6...12).contains(z) else {
            throw Abort(.badRequest, reason: "Zoom must be between 6 and 12")
        }

        // Enforce subscription tier zoom limit
        let maxZoom = req.planEntitlements.maxZoom
        guard z <= maxZoom else {
            throw Abort(.forbidden, reason: "Zoom level \(z) requires a higher subscription tier (your max: \(maxZoom)).")
        }

        // 1. Try local directory first
        let localPath = req.application.directory.workingDirectory + "Storage/tiles/\(date)/\(z)/\(x)/\(y).png"

        if FileManager.default.fileExists(atPath: localPath) {
            Self.logger.trace("Serving tile from local storage", metadata: [
                "path": "\(date)/\(z)/\(x)/\(y).png"
            ])
            let response = try await req.fileio.asyncStreamFile(at: localPath)
            response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=86400")
            return response
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

    // MARK: - GET /map/dev-tiles/:date/:z/:x/:y (unauthenticated, local only)

    @Sendable
    func getDevTile(req: Request) async throws -> Response {
        guard req.application.environment != .production else {
            throw Abort(.notFound)
        }
        guard let date = req.parameters.get("date"),
              let zStr = req.parameters.get("z"), let z = Int(zStr),
              let xStr = req.parameters.get("x"), let x = Int(xStr),
              let yStr = req.parameters.get("y"), let y = Int(yStr)
        else {
            throw Abort(.badRequest, reason: "Invalid tile parameters")
        }
        guard (6...12).contains(z) else {
            throw Abort(.badRequest, reason: "Zoom must be between 6 and 12")
        }
        let localPath = req.application.directory.workingDirectory + "Storage/tiles/\(date)/\(z)/\(x)/\(y).png"
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw Abort(.notFound)
        }
        return try await req.fileio.asyncStreamFile(at: localPath)
    }

    // MARK: - GET /map/dynamic-tiles/:date/:z/:x/:y?min_score=0.X

    @Sendable
    func getDynamicTile(req: Request) async throws -> Response {
        guard let date = req.parameters.get("date"),
              let zStr = req.parameters.get("z"), let z = Int(zStr),
              let xStr = req.parameters.get("x"), let x = Int(xStr),
              let yStr = req.parameters.get("y"), let y = Int(yStr)
        else {
            throw Abort(.badRequest, reason: "Invalid tile parameters")
        }
        guard (6...12).contains(z) else {
            throw Abort(.badRequest, reason: "Zoom must be between 6 and 12")
        }

        let maxZoom = req.planEntitlements.maxZoom
        guard z <= maxZoom else {
            throw Abort(.forbidden, reason: "Zoom level \(z) requires a higher subscription tier (your max: \(maxZoom)).")
        }

        let rawMinScore = Double(req.query[String.self, at: "min_score"] ?? "0") ?? 0
        let minScoreFraction = min(max(rawMinScore, 0.0), 1.0)

        let basePath = req.application.directory.workingDirectory + "Storage/tiles"
        guard let cached = await RasterCache.shared.get(date: date, basePath: basePath) else {
            throw Abort(.notFound, reason: "Score raster not found for \(date)")
        }
        let raster = cached.raster

        // min_score is now an absolute threshold (0.0–1.0), matching the absolute
        // scoring scale. Always at least the visibility threshold so transparent
        // points are never sampled.
        let minScore = max(minScoreFraction, Colormap.visibilityThreshold)

        let size = TileMath.tileSize
        var pixels = [PNG.RGBA<UInt8>](repeating: .init(0, 0, 0, 0), count: size * size)
        var hasData = false

        for py in 0..<size {
            for px in 0..<size {
                let (lat, lon) = TileMath.pixelToLatLon(
                    pixelX: px, pixelY: py,
                    tileX: x, tileY: y, zoom: z
                )
                if let score = raster.sample(latitude: lat, longitude: lon),
                   score >= minScore {
                    let color = Colormap.color(for: score)
                    pixels[py * size + px] = .init(color.r, color.g, color.b, color.a)
                    if color.a > 0 { hasData = true }
                }
            }
        }

        guard hasData else {
            // Return 1x1 transparent PNG for empty tiles
            throw Abort(.noContent)
        }

        let image = PNG.Image(
            packing: pixels,
            size: (x: size, y: size),
            layout: .init(format: .rgba8(palette: [], fill: nil))
        )
        var pngData: [UInt8] = []
        try image.compress(stream: &pngData, level: 1)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "image/png")
        headers.add(name: .cacheControl, value: "public, max-age=3600")
        return Response(status: .ok, headers: headers, body: .init(data: Data(pngData)))
    }

    // MARK: - GET /map/score?lat=X&lon=Y&date=YYYY-MM-DD

    struct ScoreResponse: Content {
        let latitude: Double
        let longitude: Double
        let date: String
        let score: Int?
    }

    @Sendable
    func getScore(req: Request) async throws -> ScoreResponse {
        guard let latStr = req.query[String.self, at: "lat"],
              let lonStr = req.query[String.self, at: "lon"],
              let lat = Double(latStr),
              let lon = Double(lonStr)
        else {
            throw Abort(.badRequest, reason: "Missing or invalid lat/lon query parameters")
        }

        let date: String
        if let d = req.query[String.self, at: "date"], !d.isEmpty {
            date = d
        } else {
            // Default to latest available date
            let tilesDir = req.application.directory.workingDirectory + "Storage/tiles"
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: tilesDir)) ?? []
            guard let latest = contents.filter({ formatter.date(from: $0) != nil }).sorted().last else {
                return ScoreResponse(latitude: lat, longitude: lon, date: "", score: nil)
            }
            date = latest
        }

        let basePath = req.application.directory.workingDirectory + "Storage/tiles"
        guard let cached = await RasterCache.shared.get(date: date, basePath: basePath) else {
            return ScoreResponse(latitude: lat, longitude: lon, date: date, score: nil)
        }

        let rawScore = cached.raster.sample(latitude: lat, longitude: lon)
        let score = rawScore.map { Int(($0 * 100).rounded()) }

        return ScoreResponse(latitude: lat, longitude: lon, date: date, score: score)
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

    // MARK: - GET /map/forecast-tiles/:date/:z/:x/:y

    @Sendable
    func getForecastTile(req: Request) async throws -> Response {
        guard let date = req.parameters.get("date"),
              let zStr = req.parameters.get("z"), let z = Int(zStr),
              let xStr = req.parameters.get("x"), let x = Int(xStr),
              let yStr = req.parameters.get("y"), let y = Int(yStr)
        else { throw Abort(.badRequest, reason: "Invalid tile parameters") }

        guard (6...12).contains(z) else {
            throw Abort(.badRequest, reason: "Zoom must be between 6 and 12")
        }
        let maxZoom = req.planEntitlements.maxZoom
        guard z <= maxZoom else {
            throw Abort(.forbidden, reason: "Zoom level \(z) requires a higher subscription tier")
        }

        let localPath = req.application.directory.workingDirectory
            + "Storage/tiles/forecast/\(date)/\(z)/\(x)/\(y).png"

        if FileManager.default.fileExists(atPath: localPath) {
            let response = try await req.fileio.asyncStreamFile(at: localPath)
            response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=86400")
            return response
        }

        if let s3Config = self.loadS3Config(req: req) {
            let key = "forecast/\(date)/\(z)/\(x)/\(y).png"
            let signedURL = try await self.presignedS3URL(
                bucket: s3Config.bucket, key: key, region: s3Config.region, req: req
            )
            return req.redirect(to: signedURL, redirectType: .temporary)
        }

        throw Abort(.notFound, reason: "Forecast tile not found for \(date)")
    }

    // MARK: - GET /map/forecast-dates

    @Sendable
    func getForecastDates(req: Request) async throws -> [String] {
        let forecastDir = req.application.directory.workingDirectory + "Storage/tiles/forecast"
        guard FileManager.default.fileExists(atPath: forecastDir) else {
            Self.logger.debug("Forecast tiles directory not found", metadata: ["path": "\(forecastDir)"])
            return []
        }
        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: forecastDir)
        } catch {
            Self.logger.error("Failed to list forecast tiles directory",
                              metadata: ["path": "\(forecastDir)", "error": "\(error)"])
            return []
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "Europe/Rome")

        // Today in Rome time — only return strictly future dates (forecasts for tomorrow+)
        let todayString = dateFormatter.string(from: Date())

        let dates = contents
            .filter { dateFormatter.date(from: $0) != nil && $0 > todayString }
            .sorted()
        Self.logger.debug("Forecast dates listed", metadata: ["path": "\(forecastDir)", "count": "\(dates.count)", "today": "\(todayString)", "dates": "\(dates)"])
        return dates
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
