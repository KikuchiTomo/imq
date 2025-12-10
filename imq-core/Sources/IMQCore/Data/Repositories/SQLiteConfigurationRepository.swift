import Foundation
import SQLite
import Logging

/// SQLite implementation of ConfigurationRepository protocol
/// Manages persistence of system configuration in SQLite database
/// Note: This is a single-row table with ID always set to 1
final class SQLiteConfigurationRepository: ConfigurationRepository {
    private let database: SQLiteConnectionManager
    private let logger: Logger

    // MARK: - Table and Column Definitions

    private let configurationsTable = Table("configurations")
    private let idColumn = Expression<Int64>("id")
    private let triggerLabelColumn = Expression<String>("trigger_label")
    private let githubModeColumn = Expression<String>("github_mode")
    private let pollingIntervalColumn = Expression<Double>("polling_interval")
    private let webhookSecretColumn = Expression<String?>("webhook_secret")
    private let checkConfigurationsColumn = Expression<String>("check_configurations")
    private let notificationTemplatesColumn = Expression<String>("notification_templates")
    private let updatedAtColumn = Expression<Double>("updated_at")

    /// Initialize the repository with database connection manager
    /// - Parameters:
    ///   - database: SQLite connection manager for database operations
    ///   - logger: Logger instance for debugging and monitoring
    init(database: SQLiteConnectionManager, logger: Logger) {
        self.database = database
        self.logger = logger
    }

    // MARK: - ConfigurationRepository Implementation

    /// Retrieves the system configuration
    /// - Returns: The current system configuration
    /// - Throws: DatabaseError if retrieval fails or configuration not found
    func get() async throws -> SystemConfiguration {
        try await database.withConnection { connection in
            let query = "SELECT * FROM configurations WHERE id = 1 LIMIT 1"

            let rowIterator = try connection.prepareRowIterator(query)
            guard let row = try rowIterator.failableNext() else {
                throw DatabaseError.notFound(
                    entityType: "SystemConfiguration",
                    id: "1"
                )
            }

            return try self.mapRowToConfiguration(row)
        }
    }

    /// Saves the system configuration (update only, ID is always 1)
    /// - Parameter configuration: The configuration to save
    /// - Throws: DatabaseError if save operation fails
    func save(_ configuration: SystemConfiguration) async throws {
        try await database.withConnection { connection in
            // Always use UPDATE since the row should exist (created by schema)
            // If it doesn't exist, use INSERT OR REPLACE
            let updateQuery = """
            INSERT OR REPLACE INTO configurations (
                id, trigger_label, github_mode, polling_interval,
                webhook_secret, check_configurations, notification_templates,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """

            try connection.run(
                updateQuery,
                1, // ID is always 1
                configuration.triggerLabel,
                configuration.githubMode.rawValue,
                configuration.pollingInterval,
                configuration.webhookSecret,
                configuration.checkConfigurations,
                configuration.notificationTemplates,
                configuration.updatedAt.timeIntervalSince1970
            )

            logger.debug("Saved system configuration", metadata: [
                "triggerLabel": "\(configuration.triggerLabel)",
                "githubMode": "\(configuration.githubMode.rawValue)",
                "pollingInterval": "\(configuration.pollingInterval)"
            ])
        }
    }

    // MARK: - Private Helpers

    /// Maps a database row to a SystemConfiguration entity
    /// - Parameter row: SQLite row from query result
    /// - Returns: SystemConfiguration entity
    /// - Throws: Error if mapping fails
    private func mapRowToConfiguration(_ row: Row) throws -> SystemConfiguration {
        let id = Int(try row.get(idColumn))
        let triggerLabel = try row.get(triggerLabelColumn)
        let githubModeRaw = try row.get(githubModeColumn)
        let pollingInterval = try row.get(pollingIntervalColumn)
        let webhookSecret = try row.get(webhookSecretColumn)
        let checkConfigurations = try row.get(checkConfigurationsColumn)
        let notificationTemplates = try row.get(notificationTemplatesColumn)
        let updatedAtTimestamp = try row.get(updatedAtColumn)
        let updatedAt = Date(timeIntervalSince1970: updatedAtTimestamp)

        guard let githubMode = GitHubIntegrationMode(rawValue: githubModeRaw) else {
            throw DatabaseError.invalidQuery(
                "Invalid GitHub mode: \(githubModeRaw)"
            )
        }

        return SystemConfiguration(
            id: id,
            triggerLabel: triggerLabel,
            githubMode: githubMode,
            pollingInterval: pollingInterval,
            webhookSecret: webhookSecret,
            checkConfigurations: checkConfigurations,
            notificationTemplates: notificationTemplates,
            updatedAt: updatedAt
        )
    }
}
