import Vapor

enum WeatherModule {
    static func configure(_ app: Application) throws {
        try app.register(collection: WeatherController())
    }
}
