import Fluent
import Vapor

enum SubscriptionModule {
    static func configure(_ app: Application) throws {
        app.migrations.add(CreateSubscription())
        try app.register(collection: SubscriptionController())
    }
}
