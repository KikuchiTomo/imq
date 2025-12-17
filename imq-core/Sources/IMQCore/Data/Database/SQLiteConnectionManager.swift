import Foundation
import SQLite
import Logging

/// SQLite Connection Manager with pooling support
/// Thread-safe connection management for concurrent access
public actor SQLiteConnectionManager {
    private let databasePath: String
    private var connections: [Connection] = []
    private let maxConnections: Int
    private var availableConnections: Set<Int> = []
    private let logger: Logger

    /// Initialize connection manager
    /// - Parameters:
    ///   - databasePath: Path to SQLite database file
    ///   - maxConnections: Maximum number of pooled connections (default: 5)
    public init(databasePath: String, maxConnections: Int = 5) throws {
        self.databasePath = databasePath
        self.maxConnections = maxConnections
        self.logger = Logger(label: "imq.database")

        // Ensure parent directory exists
        try Self.ensureDirectoryExists(for: databasePath)

        // Initialize connection pool
        for _ in 0..<maxConnections {
            let connection = try Connection(databasePath)
            try Self.configureConnection(connection)
            connections.append(connection)
        }

        availableConnections = Set(0..<maxConnections)

        logger.info("Initialized SQLite connection pool",
                   metadata: ["path": "\(databasePath)",
                             "poolSize": "\(maxConnections)"])
    }

    /// Acquire a connection from the pool
    /// Waits if all connections are in use
    func acquireConnection() async throws -> (Connection, Int) {
        while availableConnections.isEmpty {
            // Wait for a connection to become available
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        let index = availableConnections.removeFirst()
        return (connections[index], index)
    }

    /// Release a connection back to the pool
    func releaseConnection(index: Int) {
        availableConnections.insert(index)
    }

    /// Execute a query with automatic connection management
    public func withConnection<T>(_ operation: (Connection) async throws -> T) async throws -> T {
        let (connection, index) = try await acquireConnection()
        defer {
            Task {
                await releaseConnection(index: index)
            }
        }

        return try await operation(connection)
    }

    // MARK: - Private Helpers

    private static func ensureDirectoryExists(for path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private static func configureConnection(_ connection: Connection) throws {
        // Enable Write-Ahead Logging for better concurrent performance
        try connection.execute("PRAGMA journal_mode=WAL;")

        // Enable foreign key constraints
        try connection.execute("PRAGMA foreign_keys=ON;")

        // Set busy timeout (in milliseconds)
        try connection.execute("PRAGMA busy_timeout=5000;")

        // Optimize for performance
        try connection.execute("PRAGMA synchronous=NORMAL;")
        try connection.execute("PRAGMA temp_store=MEMORY;")
        try connection.execute("PRAGMA mmap_size=30000000000;") // 30GB
    }

    /// Initialize database schema
    func initializeSchema() async throws {
        try await withConnection { connection in
            // Load schema from Resources directory
            // For now, use a hardcoded path relative to the working directory
            let schemaPath = "Resources/schema.sql"

            guard FileManager.default.fileExists(atPath: schemaPath) else {
                throw DatabaseError.schemaNotFound
            }

            let schema = try String(contentsOfFile: schemaPath, encoding: .utf8)
            try connection.execute(schema)

            logger.info("Database schema initialized successfully")
        }
    }
}

// MARK: - Database Errors

public enum DatabaseError: Error, LocalizedError {
    case schemaNotFound
    case connectionPoolExhausted
    case invalidQuery(String)
    case constraintViolation(String)
    case notFound(entityType: String, id: String)

    public var errorDescription: String? {
        switch self {
        case .schemaNotFound:
            return "Database schema file not found"
        case .connectionPoolExhausted:
            return "All database connections are in use"
        case .invalidQuery(let query):
            return "Invalid SQL query: \(query)"
        case .constraintViolation(let detail):
            return "Database constraint violation: \(detail)"
        case .notFound(let type, let id):
            return "\(type) with id \(id) not found"
        }
    }
}
