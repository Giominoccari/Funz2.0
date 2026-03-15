import Foundation

enum ForestType: String, Codable, Sendable {
    case broadleaf
    case coniferous
    case mixed
    case none

    var score: Double {
        switch self {
        case .mixed:      return 1.0
        case .broadleaf:  return 0.85
        case .coniferous: return 0.80
        case .none:       return 0.0
        }
    }
}
