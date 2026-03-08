import Foundation

enum SoilType: String, Codable, Sendable {
    case calcareous
    case siliceous
    case mixed
    case other

    var score: Double {
        switch self {
        case .calcareous: return 1.0
        case .mixed:      return 0.8
        case .siliceous:  return 0.5
        case .other:      return 0.2
        }
    }
}
