import Fluent
import Vapor

enum AuthModule {
    static func configure(_ app: Application) throws {
        app.migrations.add(CreateUser())
        app.migrations.add(CreateRefreshToken())
        try app.register(collection: AuthController())
    }
}
