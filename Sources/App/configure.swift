import Fluent
import FluentPostgresDriver
import JWTKit
import Logging
import Redis
import SQLKit
import Vapor
 
func configure(_ app: Application) async throws {
    let logger = Logger(label: "funghi.boot")

    // PostgreSQL
    guard let databaseURL = Environment.get("DATABASE_URL") else {
        logger.critical("DATABASE_URL environment variable is not set")
        fatalError("Missing required environment variable: DATABASE_URL")
    }
    try app.databases.use(
        .postgres(
            url: databaseURL,
            maxConnectionsPerEventLoop: 8,
            connectionPoolTimeout: .seconds(30)
        ),
        as: .psql
    )
    logger.info("PostgreSQL configured")

    // Redis
    guard let redisURL = Environment.get("REDIS_URL") else {
        logger.critical("REDIS_URL environment variable is not set")
        fatalError("Missing required environment variable: REDIS_URL")
    }
    app.redis.configuration = try RedisConfiguration(url: redisURL)
    logger.info("Redis configured")

    // JWT RS256 — read private key from PEM file
    guard let jwtKeyPath = Environment.get("JWT_PRIVATE_KEY_FILE") else {
        logger.critical("JWT_PRIVATE_KEY_FILE environment variable is not set")
        fatalError("Missing required environment variable: JWT_PRIVATE_KEY_FILE")
    }
    let pemString: String
    do {
        pemString = try String(contentsOfFile: jwtKeyPath, encoding: .utf8)
    } catch {
        logger.critical("Failed to read JWT private key file", metadata: ["path": "\(jwtKeyPath)", "error": "\(error)"])
        fatalError("Cannot read JWT private key file at: \(jwtKeyPath)")
    }
    let rsaKey = try Insecure.RSA.PrivateKey(pem: pemString)
    app.jwtKeys = await JWTKeyCollection().add(rsa: rsaKey, digestAlgorithm: .sha256)
    logger.info("JWT RS256 configured", metadata: ["keyFile": "\(jwtKeyPath)"])

    // JSON date encoding: explicit ISO 8601 with fractional seconds
    let jsonEncoder = JSONEncoder()
    jsonEncoder.dateEncodingStrategy = .iso8601
    let jsonDecoder = JSONDecoder()
    jsonDecoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: jsonEncoder, for: .json)
    ContentConfiguration.global.use(decoder: jsonDecoder, for: .json)

    // Static files (Public/)
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Modules (UserModule first: CreateUser must run before CreateRefreshToken/CreateSubscription)
    try UserModule.configure(app)
    try AuthModule.configure(app)
    try SubscriptionModule.configure(app)
    try MapModule.configure(app)
    try AdminModule.configure(app)
    try WeatherModule.configure(app)

    // Migrations (auto-migrate in development)
    app.migrations.add(CreateRasterExtensions())
    app.migrations.add(CreateWeatherObservations())
    app.migrations.add(AddSoilTempColumn())
    app.migrations.add(CreateItalyBoundary())
    try await app.autoMigrate()

    // Validate PostGIS raster data (Copernicus DEM required for altitude)
    let sqlDb = app.db as! any SQLDatabase
    let tableCheck = try await sqlDb.raw("""
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_name = 'copernicus_dem'
        ) AS table_exists
        """).all()
    let tableExists = try tableCheck.first?.decode(column: "table_exists", as: Bool.self) ?? false
    if !tableExists {
        logger.warning("Table copernicus_dem does not exist — run 'make geodata-import'")
    } else {
        let rows = try await sqlDb.raw("SELECT count(*) AS c FROM copernicus_dem").all()
        let count = try rows.first?.decode(column: "c", as: Int.self) ?? 0
        if count == 0 {
            logger.warning("copernicus_dem raster table is empty — run 'make geodata-import'")
        } else {
            logger.info("PostGIS DEM validated", metadata: ["tiles": "\(count)"])
        }
    }

    // Commands
    app.asyncCommands.use(WorkerCommand(), as: "worker")
    app.asyncCommands.use(BenchGeoCommand(), as: "bench-geo")

    // Routes
    try routes(app)

    logger.info("Funz2.0 boot complete", metadata: ["version": "0.1.0"])
}
