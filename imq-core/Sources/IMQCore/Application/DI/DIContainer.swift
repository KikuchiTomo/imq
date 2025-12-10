import Foundation
import Logging

/// Dependency Injection Container
/// Manages the lifecycle of all application dependencies
final class DIContainer {

    // MARK: - Singleton

    static let shared = DIContainer()

    private init() {}

    // MARK: - Infrastructure

    private(set) lazy var configuration: ApplicationConfiguration = {
        do {
            return try ApplicationConfiguration.load()
        } catch {
            fatalError("Failed to load configuration: \(error)")
        }
    }()

    private(set) lazy var logger: Logger = {
        var logger = Logger(label: "imq")
        logger.logLevel = configuration.logLevel.swiftLogLevel
        return logger
    }()

    private(set) lazy var databaseManager: SQLiteConnectionManager = {
        do {
            let manager = try SQLiteConnectionManager(
                databasePath: configuration.databasePath,
                maxConnections: configuration.databasePoolSize
            )

            // Initialize schema on first run
            Task {
                try await manager.initializeSchema()
            }

            return manager
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }()

    // MARK: - Cleanup

    func shutdown() async {
        logger.info("Shutting down application...")
        logger.info("Application shutdown complete")
    }
}

// MARK: - Configuration Extensions

extension LogLevel {
    var swiftLogLevel: Logger.Level {
        switch self {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        case .critical: return .critical
        }
    }
}
