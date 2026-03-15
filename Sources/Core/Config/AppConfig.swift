import Foundation

struct AppConfig: Codable, Sendable {
    let server: ServerConfig
    let pipeline: PipelineConfig
    let map: MapConfig
}

struct ServerConfig: Codable, Sendable {
    let port: Int
    let maxConnections: Int
}

struct PipelineConfig: Codable, Sendable {
    let gridSpacingMeters: Int
    let batchSize: Int
    let tileZoomMin: Int
    let tileZoomMax: Int
    let scoringWeights: ScoringWeights
    let weather: WeatherConfig
}

struct WeatherConfig: Codable, Sendable {
    let baseURL: String
    let maxConcurrentRequests: Int
    let retryMaxAttempts: Int
    let retryBaseDelayMs: Int
    let cacheTTLSeconds: Int
}

struct ScoringWeights: Codable, Sendable {
    let forest: Double
    let rain14d: Double
    let temperature: Double
    let altitude: Double
    let soil: Double
}

struct MapConfig: Codable, Sendable {
    let tileSignedUrlTtlSeconds: Int
    let tileRetentionDays: Int
    let freeMaxZoom: Int
    let proMaxZoom: Int
}
