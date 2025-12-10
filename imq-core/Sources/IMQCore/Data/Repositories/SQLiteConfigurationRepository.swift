import Foundation
import SQLite
import Logging

/// SQLite implementation of ConfigurationRepository protocol
/// Manages persistence of system configuration in SQLite database
/// Note: This is a single-row table with ID always set to 1
final class SQLiteConfigurationRepository: ConfigurationRepository {
    private let database: SQLiteConnectionManager
    private let logger: Logger

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

            guard let row = try connection.prepare(query).makeIterator().next() else {
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
        let id = Int(row[0] as! Int64)
        let triggerLabel = row[1] as! String
        let githubModeRaw = row[2] as! String
        let pollingInterval = row[3] as! Double
        let webhookSecret = row[4] as? String
        let checkConfigurations = row[5] as! String
        let notificationTemplates = row[6] as! String
        let updatedAtTimestamp = row[7] as! Double
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
