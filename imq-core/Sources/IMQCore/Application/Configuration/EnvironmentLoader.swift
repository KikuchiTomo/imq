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

/// Configuration errors
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
