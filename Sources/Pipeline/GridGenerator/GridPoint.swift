import Foundation

struct GridPoint: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    var altitude: Double = 0
    var forestType: ForestType = .none
    var soilType: SoilType = .other
    var aspect: Double = 0
    /// Raw CORINE Land Cover sequential code (1-44). Used for habitat filtering.
    var corineCode: Int = 0

    /// CORINE codes where ectomycorrhizal host trees can exist.
    /// Boletus edulis is obligately ectomycorrhizal — no host tree = no Porcini.
    static let suitableCORINECodes: Set<Int> = [
        23,  // 311 — Broad-leaved forest (primary)
        24,  // 312 — Coniferous forest (primary)
        25,  // 313 — Mixed forest (primary)
        29,  // 324 — Transitional woodland-shrub (secondary)
        28,  // 323 — Sclerophyllous vegetation (secondary, Mediterranean maquis)
        27,  // 322 — Moors and heathland (marginal, Cistus zones)
        22,  // 244 — Agro-forestry areas (secondary, chestnut groves)
        26,  // 321 — Natural grasslands (marginal, scattered trees)
    ]
}

struct BoundingBox: Codable, Sendable {
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
