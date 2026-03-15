import Vapor

enum AdminModule {
    static func configure(_ app: Application) throws {
        try app.register(collection: AdminController())
    }
}
