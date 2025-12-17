import Foundation
import SQLite
import Logging
import Vapor

/// SQLite implementation of ConfigurationRepository protocol
/// Manages persistence of system configuration in SQLite database
/// Note: This is a single-row table with ID always set to 1
public final class SQLiteConfigurationRepository: ConfigurationRepository {
    private let database: SQLiteConnectionManager
    private let logger: Logger

    // MARK: - Table and Column Definitions

    private let configurationsTable = Table("configurations")
    private let idColumn = Expression<Int64>("id")
    private let triggerLabelColumn = Expression<String>("trigger_label")
    private let checkConfigurationsColumn = Expression<String>("check_configurations")
    private let notificationTemplatesColumn = Expression<String>("notification_templates")
    private let updatedAtColumn = Expression<Double>("updated_at")

    /// Initialize the repository with database connection manager
    /// - Parameters:
    ///   - database: SQLite connection manager for database operations
    ///   - logger: Logger instance for debugging and monitoring
    public init(database: SQLiteConnectionManager, logger: Logger) {
        self.database = database
        self.logger = logger
    }

    // MARK: - ConfigurationRepository Implementation

    /// Retrieves the system configuration
    /// - Returns: The current system configuration (merged with environment variables)
    /// - Throws: DatabaseError if retrieval fails or configuration not found
    public func get() async throws -> SystemConfiguration {
        let dbConfig = try await database.withConnection { connection in
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

        // Merge with environment variables (read-only values)
        return SystemConfiguration(
            id: dbConfig.id,
            triggerLabel: dbConfig.triggerLabel,
            webhookSecret: Environment.get("IMQ_WEBHOOK_SECRET"),
            webhookProxyUrl: Environment.get("IMQ_WEBHOOK_PROXY_URL"),
            checkConfigurations: dbConfig.checkConfigurations,
            notificationTemplates: dbConfig.notificationTemplates,
            updatedAt: dbConfig.updatedAt
        )
    }

    /// Saves the system configuration (update only, ID is always 1)
    /// - Parameter configuration: The configuration to save
    /// - Throws: DatabaseError if save operation fails
    /// Note: webhookSecret and webhookProxyUrl are read-only (from env) and not saved to DB
    public func save(_ configuration: SystemConfiguration) async throws {
        try await database.withConnection { connection in
            let updateQuery = """
            INSERT OR REPLACE INTO configurations (
                id, trigger_label, check_configurations, notification_templates, updated_at
            )
            VALUES (?, ?, ?, ?, ?)
            """

            try connection.run(
                updateQuery,
                1, // ID is always 1
                configuration.triggerLabel,
                configuration.checkConfigurations,
                configuration.notificationTemplates,
                configuration.updatedAt.timeIntervalSince1970
            )

            logger.debug("Saved system configuration", metadata: [
                "triggerLabel": "\(configuration.triggerLabel)"
            ])
        }
    }

    // MARK: - Private Helpers

    /// Maps a database row to a SystemConfiguration entity
    /// - Parameter row: SQLite row from query result
    /// - Returns: SystemConfiguration entity (without env values)
    /// - Throws: Error if mapping fails
    private func mapRowToConfiguration(_ row: Row) throws -> SystemConfiguration {
        let id = Int(try row.get(idColumn))
        let triggerLabel = try row.get(triggerLabelColumn)
        let checkConfigurations = try row.get(checkConfigurationsColumn)
        let notificationTemplates = try row.get(notificationTemplatesColumn)
        let updatedAtTimestamp = try row.get(updatedAtColumn)
        let updatedAt = Date(timeIntervalSince1970: updatedAtTimestamp)

        return SystemConfiguration(
            id: id,
            triggerLabel: triggerLabel,
            webhookSecret: nil, // Will be merged from env in get()
            webhookProxyUrl: nil, // Will be merged from env in get()
            checkConfigurations: checkConfigurations,
            notificationTemplates: notificationTemplates,
            updatedAt: updatedAt
        )
    }
}
