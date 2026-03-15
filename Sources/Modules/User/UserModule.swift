import Fluent
import Vapor

enum UserModule {
    static func configure(_ app: Application) throws {
        app.migrations.add(CreateUser())
        app.migrations.add(AddUserProfileFields())
        app.migrations.add(CreatePhoto())
        try app.register(collection: UserController())
    }
}
