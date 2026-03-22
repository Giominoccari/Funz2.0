import Foundation

struct IDWInterpolator: Sendable {
    private let index: SpatialIndex
    private let power: Double
    private let searchRadius: Double  // in degrees

    init(
        results: [ScoringEngine.Result],
        power: Double = 2.0,
        searchRadius: Double = 0.06  // ~6km at mid-latitudes
    ) {
        self.power = power
        self.searchRadius = searchRadius
        self.index = SpatialIndex(results: results, cellSize: searchRadius)
    }

    /// Returns interpolated score at given coordinate, or nil if no data nearby.
    func interpolate(latitude: Double, longitude: Double) -> Double? {
        let neighbors = index.query(latitude: latitude, longitude: longitude, radius: searchRadius)
        if neighbors.isEmpty { return nil }

        var weightedSum = 0.0
        var totalWeight = 0.0

        for point in neighbors {
            let dx = (point.longitude - longitude)
            let dy = (point.latitude - latitude)
            let distSq = dx * dx + dy * dy

            if distSq < 1e-12 {
                // Exactly on a data point
                return point.score
            }

            let weight = 1.0 / pow(distSq, power / 2.0)
            weightedSum += weight * point.score
            totalWeight += weight
        }

        return totalWeight > 0 ? weightedSum / totalWeight : nil
    }
}

// MARK: - Spatial Index (grid-based bucketing)

struct SpatialIndex: Sendable {
    private let cells: [CellKey: [ScoringEngine.Result]]
    private let cellSize: Double

    struct CellKey: Hashable, Sendable {
        let latCell: Int
        let lonCell: Int
    }

    init(results: [ScoringEngine.Result], cellSize: Double) {
        self.cellSize = cellSize
        var dict: [CellKey: [ScoringEngine.Result]] = [:]
        dict.reserveCapacity(results.count / 4)
        for r in results {
            let key = CellKey(
                latCell: Int(floor(r.latitude / cellSize)),
                lonCell: Int(floor(r.longitude / cellSize))
            )
            dict[key, default: []].append(r)
        }
        self.cells = dict
    }

    func query(latitude: Double, longitude: Double, radius: Double) -> [ScoringEngine.Result] {
        let centerLatCell = Int(floor(latitude / cellSize))
        let centerLonCell = Int(floor(longitude / cellSize))

        var results: [ScoringEngine.Result] = []
        let radiusSq = radius * radius

        // Search 3x3 neighboring cells
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = CellKey(latCell: centerLatCell + dLat, lonCell: centerLonCell + dLon)
                guard let cellPoints = cells[key] else { continue }
                for p in cellPoints {
                    let dx = p.longitude - longitude
                    let dy = p.latitude - latitude
                    if dx * dx + dy * dy <= radiusSq {
                        results.append(p)
                    }
                }
            }
        }

        return results
    }
}
