import Foundation

/// Pre-computed raster grid for O(1) score lookups during tile rendering.
///
/// Converts millions of scattered scoring results into a regular 2D array,
/// enabling bilinear interpolation (4 array lookups per pixel) instead of
/// expensive IDW spatial queries that search nearby points per pixel.
///
/// Memory: ~2400×2000 grid × 4 bytes ≈ 19 MB (vs. original 4.6M × 40 bytes).
struct ScoreRaster: Sendable {
    private let data: [Float]
    let width: Int
    let height: Int
    private let minLat: Double
    private let minLon: Double
    private let latStep: Double
    private let lonStep: Double

    /// Build raster from scoring results.
    /// - Parameters:
    ///   - results: Scored grid points (typically 500m spacing)
    ///   - bbox: Bounding box of the scored area
    ///   - spacingMeters: Grid spacing in meters (must match scoring grid)
    init(results: [ScoringEngine.Result], bbox: BoundingBox, spacingMeters: Double = 500) {
        let centerLat = (bbox.minLat + bbox.maxLat) / 2.0
        let latStep = spacingMeters / 111_320.0
        let lonStep = spacingMeters / (111_320.0 * cos(centerLat * .pi / 180.0))

        // Pad by 1 cell on each side to avoid edge artifacts during bilinear lookup
        let paddedMinLat = bbox.minLat - latStep
        let paddedMinLon = bbox.minLon - lonStep
        let height = Int(ceil((bbox.maxLat - paddedMinLat) / latStep)) + 2
        let width = Int(ceil((bbox.maxLon - paddedMinLon) / lonStep)) + 2

        self.minLat = paddedMinLat
        self.minLon = paddedMinLon
        self.latStep = latStep
        self.lonStep = lonStep
        self.height = height
        self.width = width

        // -1 sentinel means "no data"
        var grid = [Float](repeating: -1, count: width * height)

        for r in results {
            let col = Int(round((r.longitude - paddedMinLon) / lonStep))
            let row = Int(round((r.latitude - paddedMinLat) / latStep))
            guard col >= 0, col < width, row >= 0, row < height else { continue }
            grid[row * width + col] = Float(r.score)
        }

        self.data = ScoreRaster.gaussianBlur(grid: grid, width: width, height: height, radius: 2, sigma: 1.0)
    }

    // MARK: - Binary persistence

    /// Binary format: header (6 doubles + 2 ints = 64 bytes) + Float array
    func save(to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var buf = Data(capacity: 64 + data.count * 4)
        var vals: [Double] = [minLat, minLon, latStep, lonStep, Double(width), Double(height)]
        for i in 0..<vals.count {
            withUnsafeBytes(of: &vals[i]) { buf.append(contentsOf: $0) }
        }
        // Pad header to 64 bytes (6 doubles = 48 bytes, pad 16 more)
        buf.append(contentsOf: [UInt8](repeating: 0, count: 16))
        data.withUnsafeBytes { buf.append(contentsOf: $0) }
        try buf.write(to: URL(fileURLWithPath: path))
    }

    /// Load a previously saved raster from disk.
    static func load(from path: String) -> ScoreRaster? {
        guard let fileData = FileManager.default.contents(atPath: path),
              fileData.count >= 64 else { return nil }

        return fileData.withUnsafeBytes { buf in
            let ptr = buf.baseAddress!
            let minLat = ptr.loadUnaligned(fromByteOffset: 0, as: Double.self)
            let minLon = ptr.loadUnaligned(fromByteOffset: 8, as: Double.self)
            let latStep = ptr.loadUnaligned(fromByteOffset: 16, as: Double.self)
            let lonStep = ptr.loadUnaligned(fromByteOffset: 24, as: Double.self)
            let width = Int(ptr.loadUnaligned(fromByteOffset: 32, as: Double.self))
            let height = Int(ptr.loadUnaligned(fromByteOffset: 40, as: Double.self))

            let floatCount = (fileData.count - 64) / 4
            guard floatCount == width * height else { return nil }

            var grid = [Float](repeating: 0, count: floatCount)
            grid.withUnsafeMutableBytes { dest in
                let src = buf.baseAddress! + 64
                dest.copyMemory(from: UnsafeRawBufferPointer(start: src, count: floatCount * 4))
            }

            return ScoreRaster(
                data: grid, width: width, height: height,
                minLat: minLat, minLon: minLon,
                latStep: latStep, lonStep: lonStep
            )
        }
    }

    /// Private init for loading from disk.
    private init(
        data: [Float], width: Int, height: Int,
        minLat: Double, minLon: Double,
        latStep: Double, lonStep: Double
    ) {
        self.data = data
        self.width = width
        self.height = height
        self.minLat = minLat
        self.minLon = minLon
        self.latStep = latStep
        self.lonStep = lonStep
    }

    /// Compute min/max of non-zero scores for colormap stretching.
    func scoreRange() -> (min: Double, max: Double)? {
        var lo = Float.greatestFiniteMagnitude
        var hi = Float.leastNormalMagnitude
        var found = false
        for v in data where v > 0.001 {
            if v < lo { lo = v }
            if v > hi { hi = v }
            found = true
        }
        return found ? (min: Double(lo), max: Double(hi)) : nil
    }

    /// Fast check: does the given lat/lon bounding box contain any non-zero score data?
    /// Used to skip empty tiles before iterating 256×256 pixels.
    func hasData(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) -> Bool {
        // Map bounds to raster row/col range (clamp to grid)
        let colStart = max(0, Int(floor((minLon - self.minLon) / lonStep)))
        let colEnd = min(width - 1, Int(ceil((maxLon - self.minLon) / lonStep)))
        let rowStart = max(0, Int(floor((minLat - self.minLat) / latStep)))
        let rowEnd = min(height - 1, Int(ceil((maxLat - self.minLat) / latStep)))

        guard colStart <= colEnd, rowStart <= rowEnd else { return false }

        // Sample every 4th cell instead of every cell — still catches any non-empty region
        // since score data has ~500m spacing and tiles cover much larger areas
        let step = max(1, min((rowEnd - rowStart) / 8, (colEnd - colStart) / 8))
        for row in stride(from: rowStart, through: rowEnd, by: step) {
            for col in stride(from: colStart, through: colEnd, by: step) {
                if data[row * width + col] > 0.001 { return true }
            }
        }
        // Full scan of edges to catch thin strips missed by strided sampling
        for row in [rowStart, rowEnd] {
            for col in colStart...colEnd {
                if data[row * width + col] > 0.001 { return true }
            }
        }
        for row in rowStart...rowEnd {
            for col in [colStart, colEnd] {
                if data[row * width + col] > 0.001 { return true }
            }
        }
        return false
    }

    // MARK: - Gaussian blur

    /// Applies a Gaussian blur to the score grid.
    /// - Data cells blend with neighbors → smooths CORINE class boundaries.
    /// - No-data cells (-1) near data get filled with a weighted average → feathers forest edges.
    /// - No-data cells with no valid neighbor within radius remain -1 → no overlay.
    private static func gaussianBlur(
        grid: [Float], width: Int, height: Int,
        radius: Int, sigma: Double
    ) -> [Float] {
        // Precompute Gaussian kernel weights for offsets -radius...radius
        var kernel = [Double](repeating: 0, count: 2 * radius + 1)
        var kernelSum = 0.0
        for i in 0...(2 * radius) {
            let d = Double(i - radius)
            kernel[i] = exp(-(d * d) / (2 * sigma * sigma))
            kernelSum += kernel[i]
        }
        for i in kernel.indices { kernel[i] /= kernelSum }

        var out = [Float](repeating: -1, count: width * height)

        for row in 0..<height {
            for col in 0..<width {
                var weightedSum = 0.0
                var totalWeight = 0.0

                for dr in -radius...radius {
                    for dc in -radius...radius {
                        let r2 = row + dr
                        let c2 = col + dc
                        guard r2 >= 0, r2 < height, c2 >= 0, c2 < width else { continue }
                        let v = grid[r2 * width + c2]
                        guard v >= 0 else { continue }  // skip no-data neighbors
                        let w = kernel[dr + radius] * kernel[dc + radius]
                        weightedSum += Double(v) * w
                        totalWeight += w
                    }
                }

                if totalWeight > 0 {
                    out[row * width + col] = Float(weightedSum / totalWeight)
                }
                // else: remains -1 (no valid neighbor within radius)
            }
        }

        return out
    }

    /// Bilinear interpolation sample. Returns nil if outside data coverage.
    func sample(latitude: Double, longitude: Double) -> Double? {
        let col = (longitude - minLon) / lonStep
        let row = (latitude - minLat) / latStep

        let c0 = Int(floor(col))
        let r0 = Int(floor(row))

        guard c0 >= 0, r0 >= 0, c0 + 1 < width, r0 + 1 < height else { return nil }

        let v00 = data[r0 * width + c0]
        let v10 = data[(r0 + 1) * width + c0]
        let v01 = data[r0 * width + c0 + 1]
        let v11 = data[(r0 + 1) * width + c0 + 1]

        let fc = col - Double(c0)
        let fr = row - Double(r0)

        // Fast path: all four corners have data
        if v00 >= 0, v10 >= 0, v01 >= 0, v11 >= 0 {
            let top = Double(v00) * (1 - fc) + Double(v01) * fc
            let bot = Double(v10) * (1 - fc) + Double(v11) * fc
            return top * (1 - fr) + bot * fr
        }

        // Fallback: weighted average of valid corners only
        var sum = 0.0
        var weight = 0.0
        if v00 >= 0 { let w = (1 - fc) * (1 - fr); sum += Double(v00) * w; weight += w }
        if v01 >= 0 { let w = fc * (1 - fr); sum += Double(v01) * w; weight += w }
        if v10 >= 0 { let w = (1 - fc) * fr; sum += Double(v10) * w; weight += w }
        if v11 >= 0 { let w = fc * fr; sum += Double(v11) * w; weight += w }

        return weight > 0 ? sum / weight : nil
    }
}
