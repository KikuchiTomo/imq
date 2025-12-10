import Foundation
import Logging

/// Implementation of CheckExecutionUseCase protocol
/// Executes checks with dependency resolution and parallel execution support
final class CheckExecutionUseCaseImpl: CheckExecutionUseCase, Sendable {
    // MARK: - Properties

    private let checkExecutorFactory: CheckExecutorFactory
    private let logger: Logger

    // MARK: - Initialization

    /// Initialize check execution use case
    /// - Parameters:
    ///   - checkExecutorFactory: Factory for creating check executors
    ///   - logger: Logger for structured logging
    init(
        checkExecutorFactory: CheckExecutorFactory,
        logger: Logger
    ) {
        self.checkExecutorFactory = checkExecutorFactory
        self.logger = logger
    }

    // MARK: - CheckExecutionUseCase Protocol Implementation

    func executeChecks(
        for pullRequest: PullRequest,
        configuration: CheckConfiguration
    ) async throws -> CheckExecutionResult {
        logger.info(
            "Executing checks for pull request",
            metadata: [
                "pr": .stringConvertible(pullRequest.number),
                "repo": .string(pullRequest.repository.name),
                "checkCount": .stringConvertible(configuration.count)
            ]
        )

        // Validate configuration
        guard configuration.validate() else {
            logger.error("Invalid check configuration - validation failed")
            throw CheckExecutionError.invalidConfiguration("Check configuration validation failed")
        }

        // Get topological sort to respect dependencies
        guard let sortedChecks = configuration.topologicalSort() else {
            logger.error("Unable to sort checks - circular dependencies detected")
            throw CheckExecutionError.invalidConfiguration("Circular dependencies detected in check configuration")
        }

        // Execute checks with dependency resolution
        let results = try await executeChecksWithDependencies(
            checks: sortedChecks,
            pullRequest: pullRequest,
            configuration: configuration
        )

        // Analyze results
        let failedChecks = results.filter { $0.status == .failed }.map { $0.check.name }
        let allPassed = failedChecks.isEmpty

        logger.info(
            "Check execution completed",
            metadata: [
                "pr": .stringConvertible(pullRequest.number),
                "totalChecks": .stringConvertible(results.count),
                "passed": .stringConvertible(results.filter { $0.status == .passed }.count),
                "failed": .stringConvertible(failedChecks.count),
                "allPassed": .stringConvertible(allPassed)
            ]
        )

        return CheckExecutionResult(
            results: results,
            allPassed: allPassed,
            failedChecks: failedChecks
        )
    }

    // MARK: - Private Helper Methods

    /// Execute checks respecting dependencies and parallel execution where possible
    private func executeChecksWithDependencies(
        checks: [Check],
        pullRequest: PullRequest,
        configuration: CheckConfiguration
    ) async throws -> [CheckResult] {
        var completedResults: [CheckID: CheckResult] = [:]
        var failedCheckIDs: Set<CheckID> = []

        // Group checks by dependency level
        let checksByLevel = groupChecksByDependencyLevel(checks)

        logger.debug(
            "Grouped checks into dependency levels",
            metadata: ["levelCount": .stringConvertible(checksByLevel.count)]
        )

        // Execute checks level by level
        for (level, levelChecks) in checksByLevel.sorted(by: { $0.key < $1.key }) {
            logger.debug(
                "Executing check level",
                metadata: [
                    "level": .stringConvertible(level),
                    "checkCount": .stringConvertible(levelChecks.count)
                ]
            )

            // Check if we should skip this level due to failed dependencies
            let shouldSkipLevel = levelChecks.allSatisfy { check in
                check.dependencies.contains(where: { failedCheckIDs.contains($0) })
            }

            if shouldSkipLevel {
                logger.info(
                    "Skipping check level due to failed dependencies",
                    metadata: ["level": .stringConvertible(level)]
                )
                continue
            }

            // Execute checks in this level in parallel using TaskGroup
            let levelResults = try await withThrowingTaskGroup(of: CheckResult.self) { group in
                for check in levelChecks {
                    // Skip checks with failed dependencies
                    let hasFailed = check.dependencies.contains(where: { failedCheckIDs.contains($0) })
                    if hasFailed {
                        logger.info(
                            "Skipping check due to failed dependency",
                            metadata: ["check": .string(check.name)]
                        )
                        continue
                    }

                    group.addTask { [checkExecutorFactory, logger, pullRequest] in
                        let result = try await self.executeCheck(
                            check: check,
                            pullRequest: pullRequest,
                            factory: checkExecutorFactory,
                            logger: logger
                        )
                        return result
                    }
                }

                var results: [CheckResult] = []
                for try await result in group {
                    results.append(result)

                    // Track failed checks
                    if result.status == .failed {
                        failedCheckIDs.insert(result.check.id)

                        // If fail-fast is enabled, cancel remaining checks
                        if configuration.failFast {
                            logger.info(
                                "Fail-fast enabled, cancelling remaining checks",
                                metadata: ["failedCheck": .string(result.check.name)]
                            )
                            group.cancelAll()
                            break
                        }
                    }

                    // Store completed result
                    completedResults[result.check.id] = result
                }

                return results
            }

            // Store all level results
            for result in levelResults {
                completedResults[result.check.id] = result
            }

            // If fail-fast is enabled and we have failures, stop execution
            if configuration.failFast && !failedCheckIDs.isEmpty {
                logger.info("Stopping check execution due to fail-fast policy")
                break
            }
        }

        // Return results in original check order
        return checks.compactMap { completedResults[$0.id] }
    }

    /// Execute a single check
    private func executeCheck(
        check: Check,
        pullRequest: PullRequest,
        factory: CheckExecutorFactory,
        logger: Logger
    ) async throws -> CheckResult {
        logger.info(
            "Executing check",
            metadata: [
                "check": .string(check.name),
                "type": .string(String(describing: check.type))
            ]
        )

        let startedAt = Date()

        do {
            // Create executor for this check type
            let executor = factory.createExecutor(for: check)

            // Execute the check with timeout if configured
            let result: CheckResult
            if let timeout = check.timeout {
                result = try await withTimeout(seconds: timeout) {
                    try await executor.execute(check: check, for: pullRequest)
                }
            } else {
                result = try await executor.execute(check: check, for: pullRequest)
            }

            let completedAt = Date()
            let duration = completedAt.timeIntervalSince(startedAt)

            logger.info(
                "Check completed",
                metadata: [
                    "check": .string(check.name),
                    "status": .string(String(describing: result.status)),
                    "duration": .stringConvertible(duration)
                ]
            )

            return result
        } catch is CancellationError {
            let completedAt = Date()
            let duration = completedAt.timeIntervalSince(startedAt)

            logger.warning(
                "Check was cancelled",
                metadata: [
                    "check": .string(check.name),
                    "duration": .stringConvertible(duration)
                ]
            )

            return CheckResult(
                check: check,
                status: .cancelled,
                output: "Check was cancelled",
                startedAt: startedAt,
                completedAt: completedAt,
                duration: duration
            )
        } catch {
            let completedAt = Date()
            let duration = completedAt.timeIntervalSince(startedAt)

            logger.error(
                "Check execution failed",
                metadata: [
                    "check": .string(check.name),
                    "error": .string(error.localizedDescription),
                    "duration": .stringConvertible(duration)
                ]
            )

            return CheckResult(
                check: check,
                status: .failed,
                output: "Check failed: \(error.localizedDescription)",
                startedAt: startedAt,
                completedAt: completedAt,
                duration: duration
            )
        }
    }

    /// Group checks by their dependency level (0 = no dependencies, 1 = depends on level 0, etc.)
    private func groupChecksByDependencyLevel(_ checks: [Check]) -> [Int: [Check]] {
        var checkLevels: [CheckID: Int] = [:]
        var levels: [Int: [Check]] = [:]

        // Calculate level for each check
        func calculateLevel(for check: Check) -> Int {
            // If already calculated, return cached level
            if let level = checkLevels[check.id] {
                return level
            }

            // If no dependencies, it's level 0
            if check.dependencies.isEmpty {
                checkLevels[check.id] = 0
                return 0
            }

            // Find the max level of all dependencies
            var maxDependencyLevel = -1
            for dependencyID in check.dependencies {
                if let dependencyCheck = checks.first(where: { $0.id == dependencyID }) {
                    let dependencyLevel = calculateLevel(for: dependencyCheck)
                    maxDependencyLevel = max(maxDependencyLevel, dependencyLevel)
                }
            }

            // This check's level is one more than its highest dependency
            let level = maxDependencyLevel + 1
            checkLevels[check.id] = level
            return level
        }

        // Calculate levels for all checks
        for check in checks {
            let level = calculateLevel(for: check)
            if levels[level] == nil {
                levels[level] = []
            }
            levels[level]?.append(check)
        }

        return levels
    }

    /// Execute a task with a timeout
    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the actual operation
            group.addTask {
                try await operation()
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CheckExecutionError.pollingTimeout("Check execution timed out after \(seconds) seconds")
            }

            // Return the first result (either operation or timeout)
            guard let result = try await group.next() else {
                throw CheckExecutionError.pollingTimeout("No result from check execution")
            }

            // Cancel remaining tasks
            group.cancelAll()

            return result
        }
    }
}
