import Foundation
import Logging

/// Factory for creating check executors based on check type
///
/// Provides a centralized way to instantiate the appropriate executor
/// for each check type. Handles dependency injection for executors.
///
/// Supported check types:
/// - `.githubActions`: Returns GitHubActionsCheckExecutor
/// - `.localScript`: Returns LocalScriptCheckExecutor
final class CheckExecutorFactory: Sendable {
    private let githubGateway: GitHubGateway
    private let logger: Logger

    /// Initialize check executor factory
    ///
    /// - Parameters:
    ///   - githubGateway: Gateway for GitHub API interactions
    ///   - logger: Logger for structured logging
    init(
        githubGateway: GitHubGateway,
        logger: Logger
    ) {
        self.githubGateway = githubGateway
        self.logger = logger
    }

    /// Create an executor for the specified check type
    ///
    /// - Parameter checkType: Type of check to execute
    /// - Returns: Executor instance configured for the check type
    func createExecutor(for checkType: CheckType) -> CheckExecutor {
        switch checkType {
        case .githubActions:
            return GitHubActionsCheckExecutor(
                githubGateway: githubGateway,
                logger: logger
            )

        case .localScript:
            return LocalScriptCheckExecutor(
                logger: logger
            )
        }
    }

    /// Create an executor for a specific check
    ///
    /// Convenience method that extracts the check type and creates
    /// the appropriate executor.
    ///
    /// - Parameter check: Check to create executor for
    /// - Returns: Executor instance configured for the check
    func createExecutor(for check: Check) -> CheckExecutor {
        createExecutor(for: check.type)
    }
}
