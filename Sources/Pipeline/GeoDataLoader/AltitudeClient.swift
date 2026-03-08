import Foundation

protocol AltitudeClient: Sendable {
    func altitude(latitude: Double, longitude: Double) async throws -> Double
    func aspect(latitude: Double, longitude: Double) async throws -> Double
}

struct MockAltitudeClient: AltitudeClient {
    func altitude(latitude: Double, longitude: Double) async throws -> Double {
        // Deterministic mock: higher altitude toward north and center of Trentino
        let normalizedLat = (latitude - 45.8) / (46.5 - 45.8)
        let normalizedLon = abs((longitude - 11.3) / 0.5) // distance from center
        let base = 300.0
        let latComponent = normalizedLat * 1200.0
        let lonPenalty = normalizedLon * 400.0
        return max(base, base + latComponent - lonPenalty)
    }

    func aspect(latitude: Double, longitude: Double) async throws -> Double {
        // Deterministic mock: aspect in degrees (0-360), south-facing (~180) most favorable
        // Simple hash-like distribution based on coordinates
        let hash = (latitude * 1000 + longitude * 1000).truncatingRemainder(dividingBy: 360)
        return hash < 0 ? hash + 360 : hash
    }
}
