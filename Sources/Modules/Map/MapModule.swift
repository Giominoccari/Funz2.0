import Vapor

enum MapModule {
    static func configure(_ app: Application) throws {
        try app.register(collection: MapController())
    }
}
