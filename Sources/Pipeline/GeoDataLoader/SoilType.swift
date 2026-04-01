import Foundation

enum SoilType: String, Codable, Sendable {
    case calcareous
    case siliceous
    case mixed
    case other

    var score: Double {
        switch self {
        case .mixed:      return 1.0
        case .siliceous:  return 0.90
        case .calcareous: return 0.55
        case .other:      return 0.2
        }
    }
}
