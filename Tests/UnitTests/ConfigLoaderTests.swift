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
        #expect(config.pipeline.scoringWeights.forest == 0.30)
        #expect(config.pipeline.scoringWeights.rain14d == 0.25)
        #expect(config.pipeline.scoringWeights.temperature == 0.20)
        #expect(config.pipeline.scoringWeights.altitude == 0.15)
        #expect(config.pipeline.scoringWeights.soil == 0.10)
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

    @Test("Scoring weights sum to approximately 1.0")
    func weightsSum() throws {
        let config = try ConfigLoader.load(from: "config/app.yaml")
        let w = config.pipeline.scoringWeights
        let sum = w.forest + w.rain14d + w.temperature + w.altitude + w.soil
        #expect(abs(sum - 1.0) < 0.001)
    }
}
