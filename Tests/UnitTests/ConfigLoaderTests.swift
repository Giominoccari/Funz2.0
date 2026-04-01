import Testing
import Foundation
@testable import App

@Suite("ConfigLoader Tests")
struct ConfigLoaderTests {

    @Test("Loads valid app.yaml from project root")
    func loadValidConfig() throws {
        let config = try ConfigLoader.load(from: "config/app.yaml")
        #expect(config.server.port == 8080)
        #expect(config.server.maxConnections == 200)
        #expect(config.pipeline.gridSpacingMeters == 500)
        #expect(config.pipeline.batchSize == 5000)
        #expect(config.pipeline.tileZoomMin == 6)
        #expect(config.pipeline.tileZoomMax == 12)
        #expect(config.pipeline.scoringWeights.base.forest == 0.40)
        #expect(config.pipeline.scoringWeights.base.altitude == 0.25)
        #expect(config.pipeline.scoringWeights.base.soil == 0.20)
        #expect(config.pipeline.scoringWeights.base.aspect == 0.15)
        #expect(config.pipeline.scoringWeights.weather.rain14d == 0.40)
        #expect(config.pipeline.scoringWeights.weather.rainTrigger == 0.20)
        #expect(config.pipeline.scoringWeights.weather.temperature == 0.40)
        #expect(config.pipeline.scoringWeights.humidityMultiplierMin == 0.15)
        #expect(config.map.freeMaxZoom == 9)
        #expect(config.map.proMaxZoom == 12)
    }

    @Test("Throws on missing file")
    func missingFile() {
        #expect(throws: ConfigError.self) {
            try ConfigLoader.load(from: "nonexistent.yaml")
        }
    }

    @Test("Throws on malformed YAML")
    func malformedYaml() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("bad_config_\(UUID().uuidString).yaml")
        try "not: [valid: yaml: {{{}}}".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect(throws: ConfigError.self) {
            try ConfigLoader.load(from: tmpFile.path)
        }
    }

    @Test("Throws on missing required fields")
    func missingFields() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("partial_config_\(UUID().uuidString).yaml")
        try "server:\n  port: 8080\n".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect(throws: ConfigError.self) {
            try ConfigLoader.load(from: tmpFile.path)
        }
    }

    @Test("Base weights sum to approximately 1.0")
    func baseWeightsSum() throws {
        let config = try ConfigLoader.load(from: "config/app.yaml")
        let b = config.pipeline.scoringWeights.base
        let sum = b.forest + b.altitude + b.soil + b.aspect
        #expect(abs(sum - 1.0) < 0.001)
    }

    @Test("Weather weights sum to approximately 1.0")
    func weatherWeightsSum() throws {
        let config = try ConfigLoader.load(from: "config/app.yaml")
        let w = config.pipeline.scoringWeights.weather
        let sum = w.rain14d + w.rainTrigger + w.temperature
        #expect(abs(sum - 1.0) < 0.001)
    }
}
