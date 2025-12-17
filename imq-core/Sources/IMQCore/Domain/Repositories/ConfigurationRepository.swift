import Foundation

/// System configuration entity
/// Stores runtime configuration that can be modified through the application
public struct SystemConfiguration: Sendable {
    /// Configuration ID (always 1 - single row table)
    public let id: Int

    /// Label used to trigger merge queue operations
    public let triggerLabel: String

    /// Webhook secret for validating GitHub webhook requests
    /// Read-only: set via environment variable IMQ_WEBHOOK_SECRET
    public let webhookSecret: String?

    /// Webhook proxy URL
    /// Read-only: set via environment variable IMQ_WEBHOOK_PROXY_URL
    public let webhookProxyUrl: String?

    /// JSON string containing check configurations
    /// Defines which CI/CD checks must pass before merging
    public let checkConfigurations: String

    /// JSON string containing notification templates
    /// Defines messages for different events and notifications
    public let notificationTemplates: String

    /// Timestamp of last configuration update
    public let updatedAt: Date

    /// Creates a new system configuration
    /// - Parameters:
    ///   - id: Configuration ID (defaults to 1)
    ///   - triggerLabel: Label to trigger queue operations
    ///   - webhookSecret: Secret for webhook validation (from env)
    ///   - webhookProxyUrl: Webhook proxy URL (from env)
    ///   - checkConfigurations: JSON string of check configs
    ///   - notificationTemplates: JSON string of notification templates
    ///   - updatedAt: Last update timestamp
    public init(
        id: Int = 1,
        triggerLabel: String,
        webhookSecret: String? = nil,
        webhookProxyUrl: String? = nil,
        checkConfigurations: String,
        notificationTemplates: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.triggerLabel = triggerLabel
        self.webhookSecret = webhookSecret
        self.webhookProxyUrl = webhookProxyUrl
        self.checkConfigurations = checkConfigurations
        self.notificationTemplates = notificationTemplates
        self.updatedAt = updatedAt
    }
}

/// Repository protocol for SystemConfiguration operations
/// Manages persistence and retrieval of system configuration
/// Note: This is a single-row table with ID always set to 1
public protocol ConfigurationRepository: Sendable {
    /// Retrieves the system configuration
    /// - Returns: The current system configuration
    /// - Throws: Repository errors if retrieval fails
    func get() async throws -> SystemConfiguration

    /// Saves the system configuration (update only, ID is always 1)
    /// - Parameter configuration: The configuration to save
    /// - Throws: Repository errors if save operation fails
    func save(_ configuration: SystemConfiguration) async throws
}
