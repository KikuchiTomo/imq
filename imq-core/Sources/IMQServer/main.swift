import Vapor
import IMQCore
import Logging
import SQLite

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

let app = Application(env)
defer { app.shutdown() }

try await configure(app)
try await app.execute()

/// Configure the Vapor application
func configure(_ app: Application) async throws {
    // Configure server
    let host = Environment.get("IMQ_API_HOST") ?? "0.0.0.0"
    let port = Environment.get("IMQ_API_PORT").flatMap(Int.init) ?? 8080

    app.http.server.configuration.hostname = host
    app.http.server.configuration.port = port

    // Configure JSON encoder/decoder
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    // Configure CORS
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    app.middleware.use(cors)

    // Configure error middleware
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // Initialize database
    let dbPath = Environment.get("IMQ_DATABASE_PATH") ?? "\(NSHomeDirectory())/.imq/imq.db"
    let dbManager = try await initializeDatabase(path: dbPath, logger: app.logger)

    // Store database manager in app storage
    app.storage[DatabaseManagerKey.self] = dbManager

    // Create repositories
    let configRepo = SQLiteConfigurationRepository(database: dbManager, logger: app.logger)
    app.storage[ConfigRepositoryKey.self] = configRepo

    // Initialize configuration table with defaults if needed
    try await initializeConfiguration(repository: configRepo, logger: app.logger)

    // Register routes
    try routes(app)

    app.logger.info("IMQ Server configured successfully")
    app.logger.info("Server listening on http://\(host):\(port)")
}

/// Initialize database and create tables
func initializeDatabase(path: String, logger: Logger) async throws -> SQLiteConnectionManager {
    // Create directory if needed
    let dbURL = URL(fileURLWithPath: path)
    let directory = dbURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let manager = try SQLiteConnectionManager(databasePath: path, maxConnections: 5)

    // Create tables
    try await manager.withConnection { connection in
        // Configuration table
        try connection.run("""
        CREATE TABLE IF NOT EXISTS configurations (
            id INTEGER PRIMARY KEY,
            trigger_label TEXT NOT NULL,
            check_configurations TEXT NOT NULL,
            notification_templates TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """)

        logger.info("Database tables created successfully")
    }

    return manager
}

/// Initialize configuration with defaults if not exists
func initializeConfiguration(repository: ConfigurationRepository, logger: Logger) async throws {
    do {
        _ = try await repository.get()
        logger.info("Configuration already exists")
    } catch {
        logger.info("Initializing default configuration")
        let defaultConfig = SystemConfiguration(
            triggerLabel: Environment.get("IMQ_TRIGGER_LABEL") ?? "A-merge",
            checkConfigurations: "[]",
            notificationTemplates: "[]"
        )
        try await repository.save(defaultConfig)
        logger.info("Default configuration created")
    }
}

// MARK: - Storage Keys

struct DatabaseManagerKey: StorageKey {
    typealias Value = SQLiteConnectionManager
}

struct ConfigRepositoryKey: StorageKey {
    typealias Value = ConfigurationRepository
}
