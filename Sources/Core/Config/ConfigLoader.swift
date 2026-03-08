import Foundation
import Logging
import Yams

enum ConfigLoader {
    private static let logger = Logger(label: "funghi.config")

    static func load(from path: String = "config/app.yaml") throws -> AppConfig {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.critical("Config file not found", metadata: ["path": "\(path)"])
            throw ConfigError.fileNotFound(path)
        }

        let yamlString: String
        do {
            yamlString = try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.critical("Failed to read config file", metadata: ["path": "\(path)", "error": "\(error)"])
            throw ConfigError.readFailed(error)
        }

        let decoder = YAMLDecoder()
        do {
            let config = try decoder.decode(AppConfig.self, from: yamlString)
            logger.info("Config loaded", metadata: ["path": "\(path)"])
            return config
        } catch {
            logger.critical("Failed to decode config YAML", metadata: ["error": "\(error)"])
            throw ConfigError.decodeFailed(error)
        }
    }
}

enum ConfigError: Error {
    case fileNotFound(String)
    case readFailed(Error)
    case decodeFailed(Error)
}
