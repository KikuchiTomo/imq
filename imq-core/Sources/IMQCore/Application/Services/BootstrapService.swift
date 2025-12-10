import Foundation
import Logging

/// Bootstrap Service
/// High-level service responsible for initializing the entire application
/// Loads configuration, initializes database schema, and creates the DI container
public struct BootstrapService {
    // MARK: - Properties

    private let logger: Logger

    // MARK: - Initialization

    public init() {
        var logger = Logger(label: "imq.bootstrap")
        // Use info level during bootstrap
        logger.logLevel = .info
        self.logger = logger
    }

    // MARK: - Public Methods

    /// Bootstrap the application
    ///
    /// This method performs the complete application initialization:
    /// 1. Load application configuration from environment
    /// 2. Initialize database schema
    /// 3. Create and configure the DI container
    /// 4. Verify all critical components are accessible
    ///
    /// - Returns: Fully initialized DI container ready for use
    /// - Throws: BootstrapError if initialization fails
    ///
    /// Example:
    /// ```swift
    /// let bootstrap = BootstrapService()
    /// let container = try await bootstrap.bootstrap()
    /// ```
    public func bootstrap() async throws -> DIContainer {
        logger.info("Starting IMQ application bootstrap...")

        // Step 1: Load configuration
        logger.info("Loading application configuration...")
        let config = try loadConfiguration()
        logger.info("Configuration loaded successfully", metadata: [
            "environment": "\(config.environment)",
            "githubMode": "\(config.githubMode)",
            "databasePath": "\(config.databasePath)",
            "logLevel": "\(config.logLevel)"
        ])

        // Step 2: Create DI container
        logger.info("Creating dependency injection container...")
        let container = DIContainer(config: config)
        logger.info("DI container created")

        // Step 3: Initialize database schema
        logger.info("Initializing database schema...")
        try await initializeDatabase(container: container)
        logger.info("Database schema initialized")

        // Step 4: Verify critical components
        logger.info("Verifying critical components...")
        try await verifyCriticalComponents(container: container)
        logger.info("All critical components verified")

        // Step 5: Optional warmup
        if config.environment == .production {
            logger.info("Warming up services...")
            try await warmupServices(container: container)
            logger.info("Services warmed up")
        }

        logger.info("IMQ application bootstrap complete")
        return container
    }

    // MARK: - Private Methods

    /// Load application configuration from environment
    ///
    /// - Returns: Validated application configuration
    /// - Throws: BootstrapError if configuration loading fails
    private func loadConfiguration() throws -> ApplicationConfiguration {
        do {
            return try ApplicationConfiguration.load()
        } catch {
            logger.error("Failed to load configuration", metadata: [
                "error": "\(error.localizedDescription)"
            ])
            throw BootstrapError.configurationLoadFailed(error)
        }
    }

    /// Initialize database schema
    ///
    /// Creates all necessary tables, indexes, and constraints if they don't exist
    ///
    /// - Parameter container: DI container with database manager
    /// - Throws: BootstrapError if database initialization fails
    private func initializeDatabase(container: DIContainer) async throws {
        do {
            let dbManager = try await container.sqliteConnectionManager()
            try await dbManager.initializeSchema()
            logger.info("Database schema initialization complete")
        } catch {
            logger.error("Failed to initialize database schema", metadata: [
                "error": "\(error.localizedDescription)"
            ])
            throw BootstrapError.databaseInitializationFailed(error)
        }
    }

    /// Verify that all critical components can be instantiated
    ///
    /// This performs a basic health check by attempting to create key components
    ///
    /// - Parameter container: DI container to verify
    /// - Throws: BootstrapError if any critical component fails
    private func verifyCriticalComponents(container: DIContainer) async throws {
        do {
            // Verify database connectivity
            _ = try await container.sqliteConnectionManager()
            logger.debug("Database connectivity verified")

            // Verify repositories can be created
            _ = try await container.repositoryRepository()
            logger.debug("Repository layer verified")

            // Verify GitHub gateway can be created
            _ = try await container.githubGateway()
            logger.debug("GitHub gateway verified")

            // Verify check executor factory
            _ = try await container.checkExecutorFactory()
            logger.debug("Check executor factory verified")

            logger.info("All critical components verified successfully")
        } catch {
            logger.error("Critical component verification failed", metadata: [
                "error": "\(error.localizedDescription)"
            ])
            throw BootstrapError.componentVerificationFailed(error)
        }
    }

    /// Warmup services for production environments
    ///
    /// Pre-initializes expensive services to reduce cold start latency
    ///
    /// - Parameter container: DI container with services to warm up
    /// - Throws: BootstrapError if warmup fails
    private func warmupServices(container: DIContainer) async throws {
        do {
            // Warmup cache
            _ = try await container.checkResultCache()
            logger.debug("Cache warmed up")

            // Warmup retry policy
            _ = await container.retryPolicy()
            logger.debug("Retry policy warmed up")

            // Warmup async semaphore
            _ = try await container.asyncSemaphore(permits: 5)
            logger.debug("Async semaphore warmed up")

            logger.info("Service warmup complete")
        } catch {
            // Warmup failures are non-fatal, just log them
            logger.warning("Service warmup failed (non-fatal)", metadata: [
                "error": "\(error.localizedDescription)"
            ])
        }
    }
}

// MARK: - Error Types

/// Bootstrap service errors
public enum BootstrapError: Error, LocalizedError {
    /// Configuration loading failed
    case configurationLoadFailed(Error)

    /// Database initialization failed
    case databaseInitializationFailed(Error)

    /// Component verification failed
    case componentVerificationFailed(Error)

    /// Unknown error occurred
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .configurationLoadFailed(let error):
            return "Failed to load configuration: \(error.localizedDescription)"
        case .databaseInitializationFailed(let error):
            return "Failed to initialize database: \(error.localizedDescription)"
        case .componentVerificationFailed(let error):
            return "Failed to verify critical components: \(error.localizedDescription)"
        case .unknown(let error):
            return "Unknown bootstrap error: \(error.localizedDescription)"
        }
    }

    public var failureReason: String? {
        switch self {
        case .configurationLoadFailed:
            return "The application configuration could not be loaded from environment variables"
        case .databaseInitializationFailed:
            return "The database schema could not be initialized"
        case .componentVerificationFailed:
            return "One or more critical application components failed to initialize"
        case .unknown:
            return "An unexpected error occurred during bootstrap"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .configurationLoadFailed:
            return "Check that all required environment variables are set (especially IMQ_GITHUB_TOKEN)"
        case .databaseInitializationFailed:
            return "Check that the database path is writable and disk space is available"
        case .componentVerificationFailed:
            return "Check application logs for specific component errors"
        case .unknown:
            return "Check application logs for details"
        }
    }
}

// MARK: - Convenience Extensions

extension BootstrapService {
    /// Bootstrap with custom configuration
    ///
    /// Useful for testing or when configuration is provided programmatically
    ///
    /// - Parameter config: Pre-loaded application configuration
    /// - Returns: Fully initialized DI container
    /// - Throws: BootstrapError if initialization fails
    public func bootstrap(with config: ApplicationConfiguration) async throws -> DIContainer {
        logger.info("Starting IMQ application bootstrap with custom configuration...")

        // Create DI container
        logger.info("Creating dependency injection container...")
        let container = DIContainer(config: config)
        logger.info("DI container created")

        // Initialize database schema
        logger.info("Initializing database schema...")
        try await initializeDatabase(container: container)
        logger.info("Database schema initialized")

        // Verify critical components
        logger.info("Verifying critical components...")
        try await verifyCriticalComponents(container: container)
        logger.info("All critical components verified")

        logger.info("IMQ application bootstrap complete")
        return container
    }
}
