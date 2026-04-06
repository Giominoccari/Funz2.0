import Vapor

struct POIModule {
    static func configure(_ app: Application) throws {
        try app.register(collection: POIController())
    }
}
