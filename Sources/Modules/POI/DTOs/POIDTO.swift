import Foundation
import Vapor

enum POIDTO {
    struct CreateRequest: Content {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    struct POIResponse: Content {
        let id: UUID
        let name: String
        let latitude: Double
        let longitude: Double
        let createdAt: Date?

        init(poi: POI) {
            self.id = poi.id!
            self.name = poi.name
            self.latitude = poi.latitude
            self.longitude = poi.longitude
            self.createdAt = poi.createdAt
        }
    }
}
