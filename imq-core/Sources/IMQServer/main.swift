import Vapor
import IMQCore
import Logging
import SQLite
import AsyncHTTPClient

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
    let configRepo = IMQCore.SQLiteConfigurationRepository(database: dbManager, logger: app.logger)
    app.storage[ConfigRepositoryKey.self] = configRepo

    let queueRepo = SQLiteQueueRepository(database: dbManager, logger: app.logger)
    app.storage[QueueRepositoryKey.self] = queueRepo

    let prRepo = SQLitePullRequestRepository(database: dbManager, logger: app.logger)
    app.storage[PullRequestRepositoryKey.self] = prRepo

    // Initialize configuration table with defaults if needed
    try await initializeConfiguration(repository: configRepo, logger: app.logger)

    // Initialize GitHub Gateway
    guard let githubToken = Environment.get("IMQ_GITHUB_TOKEN") else {
        app.logger.error("IMQ_GITHUB_TOKEN environment variable not set")
        throw Abort(.internalServerError, reason: "GitHub token not configured")
    }

    let httpClient = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup))
    let githubGateway = GitHubGatewayImpl(
        httpClient: httpClient,
        token: githubToken,
        logger: app.logger
    )

    // Create check execution service
    let checkExecutionService = CheckExecutionService(
        githubGateway: githubGateway,
        logger: app.logger
    )

    // Create and start queue processing service
    let queueProcessingService = QueueProcessingService(
        app: app,
        githubGateway: githubGateway,
        checkExecutionService: checkExecutionService,
        processingInterval: 10.0,
        logger: app.logger
    )
    app.storage[QueueProcessingServiceKey.self] = queueProcessingService

    // Start queue processing in background
    Task {
        await queueProcessingService.start()
    }

    // Cleanup on shutdown
    let shutdownHandler = ShutdownHandler(
        queueProcessingService: queueProcessingService,
        httpClient: httpClient,
        logger: app.logger
    )
    app.lifecycle.use(shutdownHandler)

    // Register routes
    try routes(app)

    app.logger.info("IMQ Server configured successfully")
    app.logger.info("Server listening on http://\(host):\(port)")
    app.logger.info("Queue processing service started")
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

        // Queues table
        try connection.run("""
        CREATE TABLE IF NOT EXISTS queues (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """)

        // Pull requests table
        try connection.run("""
        CREATE TABLE IF NOT EXISTS pull_requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            title TEXT NOT NULL,
            head_branch TEXT NOT NULL,
            base_branch TEXT NOT NULL,
            head_sha TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'open',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(repository_id, number)
        )
        """)

        // Queue entries table
        try connection.run("""
        CREATE TABLE IF NOT EXISTS queue_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            queue_id INTEGER NOT NULL,
            pull_request_id INTEGER NOT NULL,
            position INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            added_at REAL NOT NULL,
            FOREIGN KEY(queue_id) REFERENCES queues(id) ON DELETE CASCADE,
            FOREIGN KEY(pull_request_id) REFERENCES pull_requests(id) ON DELETE CASCADE
        )
        """)

        // Create indices for performance
        try? connection.run("CREATE INDEX IF NOT EXISTS idx_queue_entries_queue_id ON queue_entries(queue_id)")
        try? connection.run("CREATE INDEX IF NOT EXISTS idx_queue_entries_status ON queue_entries(status)")
        try? connection.run("CREATE INDEX IF NOT EXISTS idx_pull_requests_repo_number ON pull_requests(repository_id, number)")

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

// MARK: - Lifecycle Handlers

struct ShutdownHandler: LifecycleHandler {
    let queueProcessingService: QueueProcessingService
    let httpClient: HTTPClient
    let logger: Logger

    func shutdown(_ application: Application) {
        logger.info("Shutting down IMQ Server")

        // Stop queue processing service
        Task {
            await queueProcessingService.stop()
        }

        // Shutdown HTTP client
        do {
            try httpClient.syncShutdown()
        } catch {
            logger.error("Failed to shutdown HTTP client", metadata: [
                "error": .string(error.localizedDescription)
            ])
        }

        logger.info("IMQ Server shut down complete")
    }

    func willBoot(_ application: Application) throws {
        logger.info("IMQ Server starting up")
    }
}
