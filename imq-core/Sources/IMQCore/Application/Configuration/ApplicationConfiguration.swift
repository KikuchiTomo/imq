import Foundation

/// Application Configuration
/// Loaded from environment variables and .env file
public struct ApplicationConfiguration {
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
                value: "Invalid token format (must start with ghp_, github_pat_, or ghs_)"
            )
        }

        // Validate port range
        guard (1...65535).contains(apiPort) else {
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_API_PORT",
                value: "\(apiPort) is out of valid range (1-65535)"
            )
        }

        // Validate polling interval
        guard pollingInterval >= 10 else {
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_POLLING_INTERVAL",
                value: "Polling interval must be at least 10 seconds"
            )
        }
    }

    // MARK: - Private Helpers

    private static func defaultDatabasePath() -> String {
        #if os(Linux)
        let homeDirectory: String
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            homeDirectory = home
        } else {
            homeDirectory = "/tmp"
        }
        let imqDirectory = (homeDirectory as NSString).appendingPathComponent(".imq")
        #else
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let imqDirectory = homeDirectory.appendingPathComponent(".imq").path
        #endif

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(
            atPath: imqDirectory,
            withIntermediateDirectories: true
        )

        return (imqDirectory as NSString).appendingPathComponent("imq.db") as String
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
