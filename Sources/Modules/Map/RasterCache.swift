import Foundation
import Logging

/// In-memory cache for score rasters, keyed by date.
/// Avoids re-reading ~19MB from disk on every dynamic tile request.
actor RasterCache {
    static let shared = RasterCache()

    private static let logger = Logger(label: "funghi.map.cache")
    private var entries: [String: Entry] = [:]

    private struct Entry {
        let raster: ScoreRaster
        let scoreRange: (min: Double, max: Double)?
    }

    func get(date: String, basePath: String) -> (raster: ScoreRaster, scoreRange: (min: Double, max: Double)?)? {
        if let entry = entries[date] {
            return (entry.raster, entry.scoreRange)
        }

        let path = "\(basePath)/\(date)/raster.bin"
        guard let raster = ScoreRaster.load(from: path) else { return nil }
        let scoreRange = raster.scoreRange()
        entries[date] = Entry(raster: raster, scoreRange: scoreRange)

        Self.logger.info("Raster cached", metadata: [
            "date": "\(date)",
            "size": "\(raster.width)x\(raster.height)"
        ])
        return (raster, scoreRange)
    }

    /// Evict a date entry (e.g., after pipeline re-run generates new data).
    func evict(date: String) {
        entries.removeValue(forKey: date)
    }

    /// Evict all cached rasters (called at midnight before the daily pipeline).
    func evictAll() {
        entries.removeAll()
    }
}
