import Foundation

/// System configuration entity
/// Stores runtime configuration that can be modified through the application
struct SystemConfiguration: Sendable {
    /// Configuration ID (always 1 - single row table)
    let id: Int

    /// Label used to trigger merge queue operations
    let triggerLabel: String

    /// GitHub integration mode (polling or webhook)
    let githubMode: GitHubIntegrationMode

    /// Polling interval in seconds (when in polling mode)
    let pollingInterval: TimeInterval

    /// Webhook secret for validating GitHub webhook requests (when in webhook mode)
    let webhookSecret: String?

    /// JSON string containing check configurations
    /// Defines which CI/CD checks must pass before merging
    let checkConfigurations: String

    /// JSON string containing notification templates
    /// Defines messages for different events and notifications
    let notificationTemplates: String

    /// Timestamp of last configuration update
    let updatedAt: Date

    /// Creates a new system configuration
    /// - Parameters:
    ///   - id: Configuration ID (defaults to 1)
    ///   - triggerLabel: Label to trigger queue operations
    ///   - githubMode: Integration mode with GitHub
    ///   - pollingInterval: Interval for polling mode
    ///   - webhookSecret: Secret for webhook validation
    ///   - checkConfigurations: JSON string of check configs
    ///   - notificationTemplates: JSON string of notification templates
    ///   - updatedAt: Last update timestamp
    init(
        id: Int = 1,
        triggerLabel: String,
        githubMode: GitHubIntegrationMode,
        pollingInterval: TimeInterval,
        webhookSecret: String? = nil,
        checkConfigurations: String,
        notificationTemplates: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.triggerLabel = triggerLabel
        self.githubMode = githubMode
        self.pollingInterval = pollingInterval
        self.webhookSecret = webhookSecret
        self.checkConfigurations = checkConfigurations
        self.notificationTemplates = notificationTemplates
        self.updatedAt = updatedAt
    }
}

/// Repository protocol for SystemConfiguration operations
/// Manages persistence and retrieval of system configuration
/// Note: This is a single-row table with ID always set to 1
protocol ConfigurationRepository: Sendable {
    /// Retrieves the system configuration
    /// - Returns: The current system configuration
    /// - Throws: Repository errors if retrieval fails
    func get() async throws -> SystemConfiguration

    /// Saves the system configuration (update only, ID is always 1)
    /// - Parameter configuration: The configuration to save
    /// - Throws: Repository errors if save operation fails
    func save(_ configuration: SystemConfiguration) async throws
}
