import Foundation

struct GridPoint: Sendable {
    let latitude: Double
    let longitude: Double
    var altitude: Double = 0
    var forestType: ForestType = .none
    var soilType: SoilType = .other
    var aspect: Double = 0
}

struct BoundingBox: Sendable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    static let trentino = BoundingBox(
        minLat: 45.8, maxLat: 46.5,
        minLon: 10.8, maxLon: 11.8
    )

    /// Full Italian peninsula + major islands (Sicily, Sardinia)
    static let italy = BoundingBox(
        minLat: 36.6, maxLat: 47.1,
        minLon: 6.6, maxLon: 18.5
    )
}
