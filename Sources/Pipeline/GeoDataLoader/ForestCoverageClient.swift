import Foundation

protocol ForestCoverageClient: Sendable {
    func forestType(latitude: Double, longitude: Double) async throws -> ForestType
    func soilType(latitude: Double, longitude: Double) async throws -> SoilType
}

struct MockForestCoverageClient: ForestCoverageClient {
    func forestType(latitude: Double, longitude: Double) async throws -> ForestType {
        // Deterministic mock: altitude-like bands based on latitude
        // Higher latitude in Trentino → more coniferous
        let normalizedLat = (latitude - 45.8) / (46.5 - 45.8) // 0..1 within Trentino
        if normalizedLat < 0.3 {
            return .broadleaf
        } else if normalizedLat < 0.7 {
            return .mixed
        } else {
            return .coniferous
        }
    }

    func soilType(latitude: Double, longitude: Double) async throws -> SoilType {
        // Deterministic mock: longitude-based bands
        let normalizedLon = (longitude - 10.8) / (11.8 - 10.8) // 0..1 within Trentino
        if normalizedLon < 0.4 {
            return .calcareous
        } else if normalizedLon < 0.7 {
            return .mixed
        } else {
            return .siliceous
        }
    }
}
