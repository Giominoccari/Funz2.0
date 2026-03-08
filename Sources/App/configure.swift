import Fluent
import FluentPostgresDriver
import JWTKit
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

    // JWT RS256
    guard let jwtPrivateKeyPEM = Environment.get("JWT_PRIVATE_KEY") else {
        logger.critical("JWT_PRIVATE_KEY environment variable is not set")
        fatalError("Missing required environment variable: JWT_PRIVATE_KEY")
    }
    let pemString = jwtPrivateKeyPEM.replacingOccurrences(of: "\\n", with: "\n")
    let rsaKey = try Insecure.RSA.PrivateKey(pem: pemString)
    app.jwtKeys = await JWTKeyCollection().add(rsa: rsaKey, digestAlgorithm: .sha256)
    logger.info("JWT RS256 configured")

    // Modules
    try AuthModule.configure(app)
    try UserModule.configure(app)

    // Migrations (auto-migrate in development)
    try await app.autoMigrate()

    // Routes
    try routes(app)

    logger.info("Funz2.0 boot complete", metadata: ["version": "0.1.0"])
}
