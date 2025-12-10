# Core Infrastructure Implementation

**Document Version:** 1.0
**Created:** 2025-12-10
**Status:** Implementation Ready
**Related Design Docs:**
- `../docs/03-final-design.md` - Clean Architecture
- `../docs/05-configuration-secrets-management.md` - Configuration System

## Overview

This document provides implementation-level details for IMQ's core infrastructure components:
1. SQLite Database Layer with connection pooling
2. Dependency Injection Container
3. Configuration Loading System with .env support
4. Logging Infrastructure
5. Error Handling Framework

## 1. SQLite Database Implementation

### 1.1 Database Connection Manager

**File:** `imq-core/Sources/IMQCore/Data/Database/SQLiteConnectionManager.swift`

```swift
import Foundation
import SQLite
import Logging

/// SQLite Connection Manager with pooling support
/// Thread-safe connection management for concurrent access
actor SQLiteConnectionManager {
    private let databasePath: String
    private var connections: [Connection] = []
    private let maxConnections: Int
    private var availableConnections: Set<Int> = []
    private let logger: Logger

    /// Initialize connection manager
    /// - Parameters:
    ///   - databasePath: Path to SQLite database file
    ///   - maxConnections: Maximum number of pooled connections (default: 5)
    init(databasePath: String, maxConnections: Int = 5) throws {
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
    func withConnection<T>(_ operation: (Connection) async throws -> T) async throws -> T {
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
            let schemaPath = Bundle.module.path(forResource: "schema", ofType: "sql")
            guard let path = schemaPath else {
                throw DatabaseError.schemaNotFound
            }

            let schema = try String(contentsOfFile: path, encoding: .utf8)
            try connection.execute(schema)

            logger.info("Database schema initialized successfully")
        }
    }
}

// MARK: - Database Errors

enum DatabaseError: Error, LocalizedError {
    case schemaNotFound
    case connectionPoolExhausted
    case invalidQuery(String)
    case constraintViolation(String)
    case notFound(entityType: String, id: String)

    var errorDescription: String? {
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
```

### 1.2 Type-Safe Query Builder

**File:** `imq-core/Sources/IMQCore/Data/Database/QueryBuilder.swift`

```swift
import Foundation
import SQLite

/// Protocol for tables that can be queried
protocol TableRepresentable {
    static var tableName: String { get }
    static func columnName<V>(for keyPath: KeyPath<Self, V>) -> String
}

/// Type-safe query builder for SQLite
struct Query<T: TableRepresentable> {
    private var tableName: String
    private var conditions: [Condition] = []
    private var orderByClause: [OrderBy] = []
    private var limitValue: Int?
    private var offsetValue: Int?
    private var selectColumns: [String]?

    init(table: T.Type) {
        self.tableName = T.tableName
    }

    // MARK: - Query Building

    /// Add WHERE condition
    func `where`<V: SQLiteConvertible>(
        _ keyPath: KeyPath<T, V>,
        _ op: ComparisonOperator,
        _ value: V
    ) -> Query<T> {
        var query = self
        let columnName = T.columnName(for: keyPath)
        query.conditions.append(Condition(
            column: columnName,
            operator: op,
            value: value
        ))
        return query
    }

    /// Add ORDER BY clause
    func orderBy<V>(
        _ keyPath: KeyPath<T, V>,
        _ direction: OrderDirection = .ascending
    ) -> Query<T> {
        var query = self
        let columnName = T.columnName(for: keyPath)
        query.orderByClause.append(OrderBy(
            column: columnName,
            direction: direction
        ))
        return query
    }

    /// Add LIMIT clause
    func limit(_ value: Int) -> Query<T> {
        var query = self
        query.limitValue = value
        return query
    }

    /// Build SELECT SQL statement
    func buildSelectSQL() -> (sql: String, bindings: [Binding]) {
        var sql = "SELECT "

        if let columns = selectColumns {
            sql += columns.joined(separator: ", ")
        } else {
            sql += "*"
        }

        sql += " FROM \(tableName)"

        var bindings: [Binding] = []

        // WHERE clause
        if !conditions.isEmpty {
            let conditionStrings = conditions.map { condition in
                "\(condition.column) \(condition.operator.symbol) ?"
            }
            sql += " WHERE " + conditionStrings.joined(separator: " AND ")
            bindings.append(contentsOf: conditions.map { $0.value })
        }

        // ORDER BY clause
        if !orderByClause.isEmpty {
            let orderStrings = orderByClause.map { order in
                "\(order.column) \(order.direction.rawValue)"
            }
            sql += " ORDER BY " + orderStrings.joined(separator: ", ")
        }

        // LIMIT clause
        if let limit = limitValue {
            sql += " LIMIT \(limit)"
        }

        return (sql, bindings)
    }
}

// MARK: - Supporting Types

protocol SQLiteConvertible {
    var sqliteValue: Binding { get }
}

extension String: SQLiteConvertible {
    var sqliteValue: Binding { self }
}

extension Int: SQLiteConvertible {
    var sqliteValue: Binding { Int64(self) }
}

enum ComparisonOperator {
    case equals
    case notEquals
    case greaterThan
    case lessThan

    var symbol: String {
        switch self {
        case .equals: return "="
        case .notEquals: return "!="
        case .greaterThan: return ">"
        case .lessThan: return "<"
        }
    }
}

enum OrderDirection: String {
    case ascending = "ASC"
    case descending = "DESC"
}

struct Condition {
    let column: String
    let `operator`: ComparisonOperator
    let value: Binding
}

struct OrderBy {
    let column: String
    let direction: OrderDirection
}
```

## 2. Dependency Injection Container Implementation

**File:** `imq-core/Sources/IMQCore/Application/DI/DIContainer.swift`

```swift
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

    // MARK: - Repositories

    private(set) lazy var queueRepository: QueueRepository = {
        SQLiteQueueRepository(database: databaseManager, logger: logger)
    }()

    // MARK: - Use Cases

    func makeQueueProcessingUseCase() -> QueueProcessingUseCase {
        QueueProcessingUseCaseImpl(
            queueRepository: queueRepository,
            logger: logger
        )
    }

    // MARK: - Cleanup

    func shutdown() async {
        logger.info("Shutting down application...")
        logger.info("Application shutdown complete")
    }
}
```

## 3. Configuration Management Implementation

### 3.1 Environment Loader

**File:** `imq-core/Sources/IMQCore/Application/Configuration/EnvironmentLoader.swift`

```swift
import Foundation

/// Environment Variable Loader
/// Loads configuration from .env files and system environment
struct EnvironmentLoader {
    private let dotEnvPath: String?

    init(dotEnvPath: String? = nil) {
        self.dotEnvPath = dotEnvPath
    }

    /// Load environment variables from .env file
    func load() throws {
        guard let path = dotEnvPath ?? findDotEnvFile() else {
            // .env file not found, use system environment variables only
            return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            // Skip comments and empty lines
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse KEY=VALUE
            guard let separatorIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmed[..<separatorIndex])
                .trimmingCharacters(in: .whitespaces)

            let value = String(trimmed[trimmed.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            // Set environment variable if not already set
            if getenv(key) == nil {
                setenv(key, value, 1)
            }
        }
    }

    /// Find .env file in current or parent directories
    private func findDotEnvFile() -> String? {
        let fileManager = FileManager.default
        var currentPath = fileManager.currentDirectoryPath

        // Search up to 5 parent directories
        for _ in 0..<5 {
            let dotEnvPath = (currentPath as NSString).appendingPathComponent(".env")
            if fileManager.fileExists(atPath: dotEnvPath) {
                return dotEnvPath
            }

            let parentPath = (currentPath as NSString).deletingLastPathComponent
            if parentPath == currentPath {
                break  // Reached root
            }
            currentPath = parentPath
        }

        return nil
    }
}

/// Environment Variable Helper
enum Environment {
    /// Get string value
    static func get(_ key: String) -> String? {
        guard let value = getenv(key) else {
            return nil
        }
        return String(cString: value)
    }

    /// Get string value with default
    static func get(_ key: String, default defaultValue: String) -> String {
        return get(key) ?? defaultValue
    }

    /// Get required string value (throws if not found)
    static func require(_ key: String) throws -> String {
        guard let value = get(key) else {
            throw ConfigurationError.missingRequiredEnvironmentVariable(key)
        }
        return value
    }

    /// Get integer value with default
    static func getInt(_ key: String, default defaultValue: Int) -> Int {
        guard let value = get(key), let intValue = Int(value) else {
            return defaultValue
        }
        return intValue
    }

    /// Get boolean value with default
    static func getBool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = get(key) else {
            return defaultValue
        }
        return ["true", "1", "yes", "on"].contains(value.lowercased())
    }

    /// Get double value with default
    static func getDouble(_ key: String, default defaultValue: Double) -> Double {
        guard let value = get(key), let doubleValue = Double(value) else {
            return defaultValue
        }
        return doubleValue
    }
}
```

### 3.2 Application Configuration

**File:** `imq-core/Sources/IMQCore/Application/Configuration/ApplicationConfiguration.swift`

```swift
import Foundation

/// Application Configuration
/// Loaded from environment variables and .env file
struct ApplicationConfiguration {
    // GitHub
    let githubToken: String
    let githubAPIURL: String
    let githubMode: GitHubIntegrationMode
    let pollingInterval: TimeInterval

    // Database
    let databasePath: String
    let databasePoolSize: Int

    // API Server
    let apiHost: String
    let apiPort: Int

    // Logging
    let logLevel: LogLevel
    let logFormat: LogFormat

    // Runtime
    let environment: AppEnvironment
    let debugMode: Bool

    /// Load configuration from environment
    static func load() throws -> ApplicationConfiguration {
        // Load .env file
        let loader = EnvironmentLoader()
        try loader.load()

        // GitHub Configuration
        let githubToken = try Environment.require("IMQ_GITHUB_TOKEN")
        let githubAPIURL = Environment.get("IMQ_GITHUB_API_URL", default: "https://api.github.com")
        let githubMode = try parseGitHubMode(
            Environment.get("IMQ_GITHUB_MODE", default: "polling")
        )
        let pollingInterval = Environment.getDouble("IMQ_POLLING_INTERVAL", default: 60.0)

        // Database Configuration
        let databasePath = Environment.get("IMQ_DATABASE_PATH") ?? defaultDatabasePath()
        let databasePoolSize = Environment.getInt("IMQ_DATABASE_POOL_SIZE", default: 5)

        // API Server Configuration
        let apiHost = Environment.get("IMQ_API_HOST", default: "0.0.0.0")
        let apiPort = Environment.getInt("IMQ_API_PORT", default: 8080)

        // Logging Configuration
        let logLevel = try parseLogLevel(
            Environment.get("IMQ_LOG_LEVEL", default: "info")
        )
        let logFormat = try parseLogFormat(
            Environment.get("IMQ_LOG_FORMAT", default: "pretty")
        )

        // Runtime Configuration
        let environment = try parseEnvironment(
            Environment.get("IMQ_ENVIRONMENT", default: "development")
        )
        let debugMode = Environment.getBool("IMQ_DEBUG", default: false)

        let config = ApplicationConfiguration(
            githubToken: githubToken,
            githubAPIURL: githubAPIURL,
            githubMode: githubMode,
            pollingInterval: pollingInterval,
            databasePath: databasePath,
            databasePoolSize: databasePoolSize,
            apiHost: apiHost,
            apiPort: apiPort,
            logLevel: logLevel,
            logFormat: logFormat,
            environment: environment,
            debugMode: debugMode
        )

        // Validate configuration
        try config.validate()

        return config
    }

    /// Validate configuration values
    func validate() throws {
        // Validate GitHub token format
        if !githubToken.hasPrefix("ghp_") &&
           !githubToken.hasPrefix("github_pat_") &&
           !githubToken.hasPrefix("ghs_") {
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_GITHUB_TOKEN",
                value: "Invalid token format"
            )
        }

        // Validate port range
        guard (1...65535).contains(apiPort) else {
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_API_PORT",
                value: "\(apiPort) is out of valid range (1-65535)"
            )
        }
    }

    private static func defaultDatabasePath() -> String {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let imqDirectory = homeDirectory.appendingPathComponent(".imq")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: imqDirectory,
            withIntermediateDirectories: true
        )

        return imqDirectory.appendingPathComponent("imq.db").path
    }

    private static func parseGitHubMode(_ value: String) throws -> GitHubIntegrationMode {
        switch value.lowercased() {
        case "polling":
            return .polling
        case "webhook":
            return .webhook
        default:
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_GITHUB_MODE",
                value: "Must be 'polling' or 'webhook'"
            )
        }
    }

    private static func parseLogLevel(_ value: String) throws -> LogLevel {
        switch value.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "warning": return .warning
        case "error": return .error
        case "critical": return .critical
        default:
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_LOG_LEVEL",
                value: "Must be one of: trace, debug, info, warning, error, critical"
            )
        }
    }

    private static func parseLogFormat(_ value: String) throws -> LogFormat {
        switch value.lowercased() {
        case "json": return .json
        case "pretty": return .pretty
        default:
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_LOG_FORMAT",
                value: "Must be 'json' or 'pretty'"
            )
        }
    }

    private static func parseEnvironment(_ value: String) throws -> AppEnvironment {
        switch value.lowercased() {
        case "development": return .development
        case "staging": return .staging
        case "production": return .production
        default:
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_ENVIRONMENT",
                value: "Must be 'development', 'staging', or 'production'"
            )
        }
    }
}

// MARK: - Supporting Types

enum GitHubIntegrationMode: String {
    case polling
    case webhook
}

enum LogLevel: String {
    case trace, debug, info, warning, error, critical
}

enum LogFormat {
    case json, pretty
}

enum AppEnvironment {
    case development, staging, production
}

enum ConfigurationError: Error, LocalizedError {
    case missingRequiredEnvironmentVariable(String)
    case invalidConfigurationValue(key: String, value: String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredEnvironmentVariable(let key):
            return "Required environment variable '\(key)' is not set"
        case .invalidConfigurationValue(let key, let value):
            return "Invalid value for '\(key)': \(value)"
        }
    }
}
```

## Implementation Order

### Phase 1: Foundation (Week 1)
1. Set up project structure and Package.swift
2. Implement EnvironmentLoader and ApplicationConfiguration
3. Implement SQLiteConnectionManager
4. Implement QueryBuilder
5. Create initial database schema

### Phase 2: Database Layer (Week 1-2)
1. Implement table definitions
2. Implement base repository protocols
3. Create database initialization

### Phase 3: DI Container (Week 2)
1. Implement DIContainer
2. Wire up all dependencies
3. Create factory methods for use cases

## Testing Strategy

### Unit Tests

```swift
import XCTest
@testable import IMQCore

final class EnvironmentLoaderTests: XCTestCase {
    func testLoadEnvironmentFromDotEnv() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dotEnvPath = tempDir.appendingPathComponent(".env").path

        let content = """
        IMQ_GITHUB_TOKEN=ghp_test_token
        IMQ_API_PORT=9000
        """

        try content.write(toFile: dotEnvPath, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(atPath: dotEnvPath)
        }

        let loader = EnvironmentLoader(dotEnvPath: dotEnvPath)
        try loader.load()

        XCTAssertEqual(Environment.get("IMQ_GITHUB_TOKEN"), "ghp_test_token")
        XCTAssertEqual(Environment.getInt("IMQ_API_PORT"), 9000)
    }
}
```

## Cross-Platform Considerations

### macOS vs Linux Differences

```swift
#if os(Linux)
import Glibc
#else
import Darwin
#endif

extension FileManager {
    static func homeDirectory() -> URL {
        #if os(Linux)
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return URL(fileURLWithPath: home)
        }
        return URL(fileURLWithPath: "/tmp")
        #else
        return FileManager.default.homeDirectoryForCurrentUser
        #endif
    }
}
```

---

**Next:** 02-domain-layer-implementation.md
