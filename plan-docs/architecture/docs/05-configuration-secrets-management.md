# アーキテクチャ設計 - 第5回検討（設定管理とシークレット管理）

## 検討日
2025-12-10

## 前回の問題点

**致命的なセキュリティリスク**:
- GitHub tokenなどのシークレット情報をコードに埋め込む可能性
- 環境依存の設定（database path、API URL等）がハードコードされる可能性
- .envファイルによる環境変数管理がない

## 設定管理戦略

### 設定の種類

1. **Secrets（シークレット情報）** - gitにコミットしてはいけない
   - GitHub Personal Access Token
   - Webhook Secret
   - その他のAPI keys

2. **Environment Configuration（環境依存の設定）** - 環境ごとに異なる
   - Database path
   - API Server host/port
   - Logging level
   - GitHub API base URL

3. **Application Configuration（アプリケーション設定）** - 動的に変更可能
   - Trigger label
   - Polling interval
   - Notification templates
   - Check configurations

## 実装設計

### 1. 環境変数と.envファイル

#### .env.example（テンプレート）

```bash
# /imq-core/.env.example

# ========================================
# GitHub Configuration
# ========================================
# GitHub Personal Access Token (required)
# Scopes needed: repo, workflow, read:org
IMQ_GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# GitHub API Base URL (optional, default: https://api.github.com)
IMQ_GITHUB_API_URL=https://api.github.com

# GitHub Webhook Secret (required if using webhook mode)
IMQ_GITHUB_WEBHOOK_SECRET=your-webhook-secret-here

# ========================================
# Database Configuration
# ========================================
# SQLite database file path (default: ~/.imq/imq.db)
IMQ_DATABASE_PATH=/path/to/imq.db

# Database connection pool size (default: 5)
IMQ_DATABASE_POOL_SIZE=5

# ========================================
# API Server Configuration
# ========================================
# API Server host (default: 0.0.0.0)
IMQ_API_HOST=0.0.0.0

# API Server port (default: 8080)
IMQ_API_PORT=8080

# API Server CORS origins (comma-separated, default: *)
IMQ_API_CORS_ORIGINS=http://localhost:3000,http://localhost:8080

# ========================================
# GUI Configuration
# ========================================
# GUI server host (default: 0.0.0.0)
IMQ_GUI_HOST=0.0.0.0

# GUI server port (default: 3000)
IMQ_GUI_PORT=3000

# IMQ Core API URL (default: http://localhost:8080)
IMQ_GUI_API_URL=http://localhost:8080

# ========================================
# Logging Configuration
# ========================================
# Log level: trace, debug, info, warning, error, critical (default: info)
IMQ_LOG_LEVEL=info

# Log format: json, pretty (default: pretty)
IMQ_LOG_FORMAT=pretty

# Log file path (optional, logs to stdout if not specified)
IMQ_LOG_FILE=/var/log/imq/imq.log

# ========================================
# GitHub Integration Mode
# ========================================
# GitHub integration mode: polling, webhook (default: polling)
IMQ_GITHUB_MODE=polling

# Polling interval in seconds (default: 60)
IMQ_POLLING_INTERVAL=60

# ========================================
# Runtime Configuration
# ========================================
# Application environment: development, staging, production (default: development)
IMQ_ENVIRONMENT=development

# Enable debug mode (default: false)
IMQ_DEBUG=false
```

#### .gitignore への追加

```gitignore
# /imq/.gitignore

# Environment files
.env
.env.local
.env.*.local

# Database
*.db
*.db-shm
*.db-wal

# Logs
*.log
logs/

# Configuration (除外する場合のみ)
config/local.json
config/secrets.json
```

### 2. Configuration Loader（Swift）

#### Environment Variable Loader

```swift
// /imq-core/Sources/IMQCore/Application/Configuration/EnvironmentLoader.swift

import Foundation

/**
 * Environment Variable Loader
 * .envファイルと環境変数から設定を読み込む
 */
struct EnvironmentLoader {
    private let dotEnvPath: String?

    init(dotEnvPath: String? = nil) {
        self.dotEnvPath = dotEnvPath
    }

    /**
     * Load environment from .env file
     */
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
            if let separatorIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: separatorIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

                // Set environment variable (if not already set)
                if getenv(key) == nil {
                    setenv(key, value, 1)
                }
            }
        }
    }

    /**
     * Find .env file in current directory or parent directories
     */
    private func findDotEnvFile() -> String? {
        let fileManager = FileManager.default
        var currentPath = fileManager.currentDirectoryPath

        for _ in 0..<5 {  // Search up to 5 parent directories
            let dotEnvPath = (currentPath as NSString).appendingPathComponent(".env")
            if fileManager.fileExists(atPath: dotEnvPath) {
                return dotEnvPath
            }

            let parentPath = (currentPath as NSString).deletingLastPathComponent
            if parentPath == currentPath {
                break  // Reached root directory
            }
            currentPath = parentPath
        }

        return nil
    }
}

/**
 * Environment Variable Helper
 */
enum Environment {
    /**
     * Get string value
     */
    static func get(_ key: String) -> String? {
        guard let value = getenv(key) else {
            return nil
        }
        return String(cString: value)
    }

    /**
     * Get string value with default
     */
    static func get(_ key: String, default defaultValue: String) -> String {
        return get(key) ?? defaultValue
    }

    /**
     * Get required string value (throws if not found)
     */
    static func require(_ key: String) throws -> String {
        guard let value = get(key) else {
            throw ConfigurationError.missingRequiredEnvironmentVariable(key)
        }
        return value
    }

    /**
     * Get integer value
     */
    static func getInt(_ key: String) -> Int? {
        guard let value = get(key) else {
            return nil
        }
        return Int(value)
    }

    /**
     * Get integer value with default
     */
    static func getInt(_ key: String, default defaultValue: Int) -> Int {
        return getInt(key) ?? defaultValue
    }

    /**
     * Get boolean value
     */
    static func getBool(_ key: String) -> Bool? {
        guard let value = get(key) else {
            return nil
        }
        return ["true", "1", "yes"].contains(value.lowercased())
    }

    /**
     * Get boolean value with default
     */
    static func getBool(_ key: String, default defaultValue: Bool) -> Bool {
        return getBool(key) ?? defaultValue
    }

    /**
     * Get double value
     */
    static func getDouble(_ key: String) -> Double? {
        guard let value = get(key) else {
            return nil
        }
        return Double(value)
    }

    /**
     * Get double value with default
     */
    static func getDouble(_ key: String, default defaultValue: Double) -> Double {
        return getDouble(key) ?? defaultValue
    }
}

enum ConfigurationError: Error {
    case missingRequiredEnvironmentVariable(String)
    case invalidConfigurationValue(key: String, value: String)
}
```

#### Application Configuration

```swift
// /imq-core/Sources/IMQCore/Application/Configuration/ApplicationConfiguration.swift

/**
 * Application Configuration
 * 環境変数から設定を読み込む
 */
struct ApplicationConfiguration {
    // GitHub
    let githubToken: String
    let githubAPIURL: String
    let githubWebhookSecret: String?
    let githubMode: GitHubIntegrationMode
    let pollingInterval: TimeInterval

    // Database
    let databasePath: String
    let databasePoolSize: Int

    // API Server
    let apiHost: String
    let apiPort: Int
    let corsOrigins: [String]

    // Logging
    let logLevel: LogLevel
    let logFormat: LogFormat
    let logFilePath: String?

    // Runtime
    let environment: AppEnvironment
    let debugMode: Bool

    /**
     * Load from environment variables
     */
    static func load() throws -> ApplicationConfiguration {
        // Load .env file
        let loader = EnvironmentLoader()
        try loader.load()

        // GitHub Configuration
        let githubToken = try Environment.require("IMQ_GITHUB_TOKEN")
        let githubAPIURL = Environment.get("IMQ_GITHUB_API_URL", default: "https://api.github.com")
        let githubWebhookSecret = Environment.get("IMQ_GITHUB_WEBHOOK_SECRET")
        let githubMode = try parseGitHubMode(Environment.get("IMQ_GITHUB_MODE", default: "polling"))
        let pollingInterval = Environment.getDouble("IMQ_POLLING_INTERVAL", default: 60.0)

        // Database Configuration
        let databasePath = Environment.get("IMQ_DATABASE_PATH") ?? defaultDatabasePath()
        let databasePoolSize = Environment.getInt("IMQ_DATABASE_POOL_SIZE", default: 5)

        // API Server Configuration
        let apiHost = Environment.get("IMQ_API_HOST", default: "0.0.0.0")
        let apiPort = Environment.getInt("IMQ_API_PORT", default: 8080)
        let corsOrigins = Environment.get("IMQ_API_CORS_ORIGINS", default: "*")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Logging Configuration
        let logLevel = try parseLogLevel(Environment.get("IMQ_LOG_LEVEL", default: "info"))
        let logFormat = try parseLogFormat(Environment.get("IMQ_LOG_FORMAT", default: "pretty"))
        let logFilePath = Environment.get("IMQ_LOG_FILE")

        // Runtime Configuration
        let environment = try parseEnvironment(Environment.get("IMQ_ENVIRONMENT", default: "development"))
        let debugMode = Environment.getBool("IMQ_DEBUG", default: false)

        return ApplicationConfiguration(
            githubToken: githubToken,
            githubAPIURL: githubAPIURL,
            githubWebhookSecret: githubWebhookSecret,
            githubMode: githubMode,
            pollingInterval: pollingInterval,
            databasePath: databasePath,
            databasePoolSize: databasePoolSize,
            apiHost: apiHost,
            apiPort: apiPort,
            corsOrigins: corsOrigins,
            logLevel: logLevel,
            logFormat: logFormat,
            logFilePath: logFilePath,
            environment: environment,
            debugMode: debugMode
        )
    }

    /**
     * Validate configuration
     */
    func validate() throws {
        // Validate GitHub token format
        if !githubToken.hasPrefix("ghp_") && !githubToken.hasPrefix("github_pat_") {
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_GITHUB_TOKEN",
                value: "Invalid token format"
            )
        }

        // Validate webhook secret if webhook mode
        if githubMode == .webhook && githubWebhookSecret == nil {
            throw ConfigurationError.missingRequiredEnvironmentVariable("IMQ_GITHUB_WEBHOOK_SECRET")
        }

        // Validate port range
        if apiPort < 1 || apiPort > 65535 {
            throw ConfigurationError.invalidConfigurationValue(
                key: "IMQ_API_PORT",
                value: "\(apiPort) is out of range"
            )
        }
    }

    /**
     * Default database path
     */
    private static func defaultDatabasePath() -> String {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let imqDirectory = homeDirectory.appendingPathComponent(".imq")

        // Create directory if not exists
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
                value: value
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
                value: value
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
                value: value
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
                value: value
            )
        }
    }
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
```

### 3. GUI Configuration (JavaScript)

#### config.js

```javascript
// /Resources/Public/js/config/config.js

/**
 * GUI Configuration
 * 環境変数またはwindow.IMQ_CONFIGから読み込む
 */
class Configuration {
    constructor() {
        // Load from window object (set by Leaf template)
        const envConfig = window.IMQ_CONFIG || {};

        this.apiURL = envConfig.apiURL || this.getEnvVar('IMQ_GUI_API_URL', 'http://localhost:8080');
        this.wsURL = envConfig.wsURL || this.getEnvVar('IMQ_GUI_WS_URL', 'ws://localhost:8080/ws/events');
        this.environment = envConfig.environment || this.getEnvVar('IMQ_ENVIRONMENT', 'development');
        this.debugMode = envConfig.debugMode || this.getEnvVar('IMQ_DEBUG', 'false') === 'true';
    }

    /**
     * Get environment variable (for development)
     */
    getEnvVar(key, defaultValue) {
        if (typeof process !== 'undefined' && process.env) {
            return process.env[key] || defaultValue;
        }
        return defaultValue;
    }

    /**
     * Is development environment
     */
    isDevelopment() {
        return this.environment === 'development';
    }

    /**
     * Is production environment
     */
    isProduction() {
        return this.environment === 'production';
    }
}

// Singleton instance
export const config = new Configuration();
```

#### Leaf Template での設定注入

```html
<!-- Resources/Views/layout.leaf -->
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <title>#(title) - IMQ</title>

    <!-- Configuration injection -->
    <script>
        window.IMQ_CONFIG = {
            apiURL: '#(config.apiURL)',
            wsURL: '#(config.wsURL)',
            environment: '#(config.environment)',
            debugMode: #(config.debugMode)
        };
    </script>

    <script src="https://cdn.tailwindcss.com"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"></script>
</head>
<body>
    #import("content")
</body>
</html>
```

### 4. Secrets Management（本番環境）

#### 推奨される運用方法

##### Development環境
```bash
# .envファイルを使用
cp .env.example .env
# 編集して必要な値を設定
vim .env
```

##### Production環境（オプション）

1. **システム環境変数**
```bash
# /etc/systemd/system/imq.service
[Service]
Environment="IMQ_GITHUB_TOKEN=ghp_xxx"
Environment="IMQ_DATABASE_PATH=/var/lib/imq/imq.db"
EnvironmentFile=/etc/imq/secrets.env
```

2. **Docker Secrets**（Docker使用時）
```yaml
# docker-compose.yml
services:
  imq-core:
    image: imq-core:latest
    env_file:
      - .env
    secrets:
      - github_token
    environment:
      IMQ_GITHUB_TOKEN_FILE: /run/secrets/github_token

secrets:
  github_token:
    external: true
```

3. **Kubernetes Secrets**（Kubernetes使用時）
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: imq-secrets
type: Opaque
stringData:
  github-token: "ghp_xxx"
  webhook-secret: "secret"
---
apiVersion: v1
kind: Pod
metadata:
  name: imq-core
spec:
  containers:
  - name: imq-core
    envFrom:
    - secretRef:
        name: imq-secrets
```

#### Secrets File Reader（オプション）

```swift
// /imq-core/Sources/IMQCore/Application/Configuration/SecretsLoader.swift

/**
 * Secrets File Loader
 * Docker SecretsやKubernetes Secretsからの読み込みをサポート
 */
struct SecretsLoader {
    /**
     * Load secret from file
     * If environment variable ends with _FILE, read from file
     */
    static func loadSecretFromFile(_ key: String) -> String? {
        let fileKey = "\(key)_FILE"

        guard let filePath = Environment.get(fileKey) else {
            return nil
        }

        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("Warning: Failed to read secret from file \(filePath): \(error)")
            return nil
        }
    }

    /**
     * Get secret (from file or environment variable)
     */
    static func getSecret(_ key: String) -> String? {
        // Try to load from file first
        if let secret = loadSecretFromFile(key) {
            return secret
        }

        // Fallback to environment variable
        return Environment.get(key)
    }

    /**
     * Require secret (throws if not found)
     */
    static func requireSecret(_ key: String) throws -> String {
        guard let secret = getSecret(key) else {
            throw ConfigurationError.missingRequiredEnvironmentVariable(key)
        }
        return secret
    }
}

// Usage in ApplicationConfiguration
let githubToken = try SecretsLoader.requireSecret("IMQ_GITHUB_TOKEN")
```

### 5. Configuration Validation

#### Startup Validation

```swift
// /imq-core/Sources/IMQCLI/main.swift

import Foundation

@main
struct IMQCLIMain {
    static func main() async throws {
        // Load configuration
        let config = try ApplicationConfiguration.load()

        // Validate configuration
        try config.validate()

        // Print configuration summary (mask secrets)
        printConfigurationSummary(config)

        // Run CLI
        await IMQCommand.main()
    }

    static func printConfigurationSummary(_ config: ApplicationConfiguration) {
        print("=== IMQ Configuration ===")
        print("Environment: \(config.environment)")
        print("GitHub Mode: \(config.githubMode)")
        print("GitHub Token: \(maskSecret(config.githubToken))")
        print("Database Path: \(config.databasePath)")
        print("API Server: \(config.apiHost):\(config.apiPort)")
        print("Log Level: \(config.logLevel)")
        print("========================")
    }

    static func maskSecret(_ secret: String) -> String {
        guard secret.count > 8 else {
            return "***"
        }
        let prefix = secret.prefix(4)
        let suffix = secret.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
```

## セキュリティベストプラクティス

### 1. .envファイルの管理
- ✅ `.env`を`.gitignore`に追加
- ✅ `.env.example`をリポジトリに含める（値は空またはダミー）
- ✅ チームメンバーへの共有は暗号化されたチャネルで

### 2. GitHub Tokenの権限
- ✅ 必要最小限のスコープのみ付与
  - `repo`: リポジトリアクセス
  - `workflow`: GitHub Actions操作
  - `read:org`: 組織情報の読み取り
- ✅ Fine-grained tokenの使用を推奨

### 3. Webhook Secretの生成
```bash
# 安全なランダム文字列の生成
openssl rand -hex 32
```

### 4. ログへのシークレット出力防止
```swift
// Bad
logger.info("GitHub token: \(githubToken)")

// Good
logger.info("GitHub token: \(maskSecret(githubToken))")
```

## まとめ

### 設定管理の階層

1. **環境変数** - 最優先
2. **.envファイル** - 開発環境用
3. **デフォルト値** - フォールバック

### セキュリティ

- ✅ Secretsはgitにコミットしない
- ✅ 環境変数で管理
- ✅ ログにマスキングして出力
- ✅ 必要最小限の権限のみ付与

### 拡張性

- ✅ 新しい設定項目の追加が容易
- ✅ 環境ごとの設定切り替えが容易
- ✅ Docker/Kubernetes対応

## 次の実装ドキュメント

設定管理の設計が完了したので、次は各機能の詳細設計に進みます。
