import Fluent
import FluentPostgresDriver
import Logging
import Redis
import Vapor

func configure(_ app: Application) async throws {
    let logger = Logger(label: "funghi.boot")

    // PostgreSQL
    guard let databaseURL = Environment.get("DATABASE_URL") else {
        logger.critical("DATABASE_URL environment variable is not set")
        fatalError("Missing required environment variable: DATABASE_URL")
    }
    try app.databases.use(.postgres(url: databaseURL), as: .psql)
    logger.info("PostgreSQL configured")

    // Redis
    guard let redisURL = Environment.get("REDIS_URL") else {
        logger.critical("REDIS_URL environment variable is not set")
        fatalError("Missing required environment variable: REDIS_URL")
    }
    app.redis.configuration = try RedisConfiguration(url: redisURL)
    logger.info("Redis configured")

    // Routes
    try routes(app)

    logger.info("Funz2.0 boot complete", metadata: ["version": "0.1.0"])
}
