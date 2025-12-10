# Check Executor Factory and Parallel Execution Implementation

**Document Version:** 1.0
**Created:** 2025-12-10
**Status:** Implementation Ready
**Related Design Docs:**
- `../docs/01-basic-check-design.md` - Check types and execution
- `../docs/03-final-design.md` - Parallel execution and caching

## Overview

Implementation details for the Check Executor Factory pattern, parallel execution with semaphore control, and SHA-based result caching.

## Critical Files to Create

1. `imq-core/Sources/IMQCore/Data/CheckExecution/CheckExecutorFactory.swift` - Factory for creating executors
2. `imq-core/Sources/IMQCore/Domain/UseCases/CheckExecutionUseCase.swift` - Parallel execution logic
3. `imq-core/Sources/IMQCore/Application/Caching/CheckResultCache.swift` - Result caching actor
4. `imq-core/Sources/IMQCore/Data/CheckExecution/CheckExecutor.swift` - Executor protocol

## 1. Check Executor Protocol

**File:** `imq-core/Sources/IMQCore/Data/CheckExecution/CheckExecutor.swift`

### Protocol Definition

```swift
import Foundation

/// Protocol for executing checks on pull requests
protocol CheckExecutor {
    /// Execute a check
    /// - Parameters:
    ///   - check: The check configuration
    ///   - pullRequest: The pull request to check
    /// - Returns: Check execution result
    func execute(check: Check, for pullRequest: PullRequest) async throws -> CheckResult
}

// MARK: - Check Result

struct CheckResult {
    let check: Check
    let status: CheckStatus
    let output: String?
    let startedAt: Date
    let completedAt: Date
    let duration: TimeInterval

    var success: Bool {
        status == .passed
    }
}

enum CheckStatus: String {
    case pending = "pending"
    case running = "running"
    case passed = "passed"
    case failed = "failed"
    case cancelled = "cancelled"
    case timedOut = "timed_out"
}
```

## 2. Check Executor Factory

**File:** `imq-core/Sources/IMQCore/Data/CheckExecution/CheckExecutorFactory.swift`

### Implementation

```swift
import Foundation
import Logging

/// Factory for creating check executors based on check type
final class CheckExecutorFactory {
    private let githubGateway: GitHubGateway
    private let logger: Logger

    init(githubGateway: GitHubGateway, logger: Logger) {
        self.githubGateway = githubGateway
        self.logger = logger
    }

    /// Create executor for check type
    func makeExecutor(for checkType: CheckType) -> CheckExecutor {
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
}

enum CheckType: String, Codable {
    case githubActions = "github_actions"
    case localScript = "local_script"
}
```

## 3. Check Execution Use Case

**File:** `imq-core/Sources/IMQCore/Domain/UseCases/CheckExecutionUseCase.swift`

### Protocol Definition

```swift
import Foundation

protocol CheckExecutionUseCase {
    /// Execute all checks for a pull request
    func executeChecks(
        for pullRequest: PullRequest,
        configuration: CheckConfiguration
    ) async throws -> CheckExecutionResult
}

struct CheckExecutionResult {
    let results: [CheckResult]
    let allPassed: Bool
    let failedChecks: [String]
}
```

### Implementation with Parallel Execution

```swift
import Foundation
import Logging

final class CheckExecutionUseCaseImpl: CheckExecutionUseCase {
    private let factory: CheckExecutorFactory
    private let resultCache: CheckResultCache
    private let semaphore: AsyncSemaphore
    private let logger: Logger

    // Configuration
    private let maxConcurrentChecks: Int
    private let defaultTimeout: TimeInterval

    init(
        factory: CheckExecutorFactory,
        resultCache: CheckResultCache,
        maxConcurrentChecks: Int = 5,
        defaultTimeout: TimeInterval = 600,
        logger: Logger
    ) {
        self.factory = factory
        self.resultCache = resultCache
        self.maxConcurrentChecks = maxConcurrentChecks
        self.defaultTimeout = defaultTimeout
        self.logger = logger

        self.semaphore = AsyncSemaphore(value: maxConcurrentChecks)
    }

    func executeChecks(
        for pullRequest: PullRequest,
        configuration: CheckConfiguration
    ) async throws -> CheckExecutionResult {
        logger.info("Executing checks for PR #\(pullRequest.number)",
                   metadata: ["repo": "\(pullRequest.repository.fullName)",
                             "pr": "\(pullRequest.number)",
                             "sha": "\(pullRequest.headSHA)",
                             "checkCount": "\(configuration.checks.count)"])

        // Check cache first
        if let cachedResult = await resultCache.getResult(for: pullRequest.headSHA) {
            logger.info("Using cached check results for SHA \(pullRequest.headSHA)")
            return cachedResult
        }

        // Execute checks in parallel with concurrency limit
        let results = try await executeChecksInParallel(
            checks: configuration.checks,
            pullRequest: pullRequest
        )

        // Aggregate results
        let allPassed = results.allSatisfy { $0.success }
        let failedChecks = results
            .filter { !$0.success }
            .map { $0.check.name }

        let executionResult = CheckExecutionResult(
            results: results,
            allPassed: allPassed,
            failedChecks: failedChecks
        )

        // Cache results
        await resultCache.saveResult(executionResult, for: pullRequest.headSHA)

        logger.info("Check execution complete",
                   metadata: ["allPassed": "\(allPassed)",
                             "passedCount": "\(results.filter { $0.success }.count)",
                             "failedCount": "\(failedChecks.count)"])

        return executionResult
    }

    // MARK: - Parallel Execution

    private func executeChecksInParallel(
        checks: [Check],
        pullRequest: PullRequest
    ) async throws -> [CheckResult] {
        try await withThrowingTaskGroup(of: (Int, CheckResult).self) { group in
            var results: [CheckResult?] = Array(repeating: nil, count: checks.count)

            // Add tasks for each check
            for (index, check) in checks.enumerated() {
                group.addTask {
                    // Acquire semaphore
                    await self.semaphore.wait()
                    defer {
                        Task { await self.semaphore.signal() }
                    }

                    let result = try await self.executeCheckWithTimeout(
                        check: check,
                        pullRequest: pullRequest
                    )

                    return (index, result)
                }
            }

            // Collect results
            for try await (index, result) in group {
                results[index] = result

                // Fail-fast: if a check fails, cancel remaining
                if !result.success {
                    logger.warning("Check failed: \(result.check.name), cancelling remaining checks")
                    group.cancelAll()
                    break
                }
            }

            // Return completed results
            return results.compactMap { $0 }
        }
    }

    private func executeCheckWithTimeout(
        check: Check,
        pullRequest: PullRequest
    ) async throws -> CheckResult {
        let timeout = check.timeout ?? defaultTimeout

        logger.debug("Executing check: \(check.name)",
                    metadata: ["type": "\(check.type)",
                              "timeout": "\(timeout)s"])

        do {
            return try await withTimeout(seconds: timeout) {
                let executor = self.factory.makeExecutor(for: check.type)
                return try await executor.execute(check: check, for: pullRequest)
            }

        } catch is TimeoutError {
            logger.error("Check timed out: \(check.name)")

            return CheckResult(
                check: check,
                status: .timedOut,
                output: "Check execution timed out after \(timeout) seconds",
                startedAt: Date(),
                completedAt: Date(),
                duration: timeout
            )

        } catch {
            logger.error("Check execution failed: \(check.name) - \(error)")

            return CheckResult(
                check: check,
                status: .failed,
                output: "Check execution error: \(error.localizedDescription)",
                startedAt: Date(),
                completedAt: Date(),
                duration: 0
            )
        }
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.operationTimedOut(seconds: seconds)
            }

            guard let result = try await group.next() else {
                throw TimeoutError.noResult
            }

            group.cancelAll()
            return result
        }
    }
}

enum TimeoutError: Error {
    case operationTimedOut(seconds: TimeInterval)
    case noResult
}
```

## 4. Check Result Cache

**File:** `imq-core/Sources/IMQCore/Application/Caching/CheckResultCache.swift`

### Implementation

```swift
import Foundation

/// Actor-based cache for check results
/// Results are cached by commit SHA to avoid re-running checks
actor CheckResultCache {
    // SHA -> CheckExecutionResult
    private var cache: [String: CachedResult] = [:]

    // Configuration
    private let maxCacheSize: Int
    private let expirationTime: TimeInterval

    init(maxCacheSize: Int = 1000, expirationTime: TimeInterval = 3600) {
        self.maxCacheSize = maxCacheSize
        self.expirationTime = expirationTime
    }

    /// Get cached result for SHA
    func getResult(for sha: String) -> CheckExecutionResult? {
        guard let cached = cache[sha] else {
            return nil
        }

        // Check if expired
        if Date().timeIntervalSince(cached.timestamp) > expirationTime {
            cache.removeValue(forKey: sha)
            return nil
        }

        return cached.result
    }

    /// Save result to cache
    func saveResult(_ result: CheckExecutionResult, for sha: String) {
        // Evict old entries if cache is full
        if cache.count >= maxCacheSize {
            evictOldestEntries()
        }

        cache[sha] = CachedResult(
            result: result,
            timestamp: Date()
        )
    }

    /// Clear all cached results
    func clearAll() {
        cache.removeAll()
    }

    /// Clear cached result for specific SHA
    func clearResult(for sha: String) {
        cache.removeValue(forKey: sha)
    }

    // MARK: - Private Methods

    private func evictOldestEntries() {
        let entriesToRemove = cache.count - maxCacheSize + 100

        let oldestEntries = cache
            .sorted { $0.value.timestamp < $1.value.timestamp }
            .prefix(entriesToRemove)

        for (sha, _) in oldestEntries {
            cache.removeValue(forKey: sha)
        }
    }
}

// MARK: - Supporting Types

private struct CachedResult {
    let result: CheckExecutionResult
    let timestamp: Date
}
```

## 5. Check Configuration

**File:** `imq-core/Sources/IMQCore/Domain/Entities/Check.swift`

### Entity Definition

```swift
import Foundation

struct Check: Identifiable, Codable {
    let id: CheckID
    let name: String
    let type: CheckType
    let configuration: CheckTypeConfiguration
    let timeout: TimeInterval?
    let dependencies: [CheckID]

    var requiresAllDependencies: Bool {
        !dependencies.isEmpty
    }
}

struct CheckID: Hashable, Codable {
    let value: String

    init(_ value: String = UUID().uuidString) {
        self.value = value
    }
}

enum CheckTypeConfiguration: Codable {
    case githubActions(GitHubActionsConfig)
    case localScript(LocalScriptConfig)
}

struct GitHubActionsConfig: Codable {
    let workflowName: String
    let ref: String?
}

struct LocalScriptConfig: Codable {
    let scriptPath: String
    let arguments: [String]
    let environment: [String: String]
}

struct CheckConfiguration: Codable {
    let checks: [Check]
    let failFast: Bool

    init(checks: [Check], failFast: Bool = true) {
        self.checks = checks
        self.failFast = failFast
    }
}
```

## Testing Strategy

### Unit Tests

```swift
import XCTest
@testable import IMQCore

final class CheckExecutionUseCaseTests: XCTestCase {
    var useCase: CheckExecutionUseCaseImpl!
    var mockFactory: MockCheckExecutorFactory!
    var cache: CheckResultCache!

    override func setUp() async throws {
        mockFactory = MockCheckExecutorFactory()
        cache = CheckResultCache()
        useCase = CheckExecutionUseCaseImpl(
            factory: mockFactory,
            resultCache: cache,
            maxConcurrentChecks: 3,
            logger: Logger(label: "test")
        )
    }

    func testParallelExecution() async throws {
        let checks = (0..<5).map { index in
            Check(
                id: CheckID("\(index)"),
                name: "Check \(index)",
                type: .localScript,
                configuration: .localScript(LocalScriptConfig(
                    scriptPath: "/bin/true",
                    arguments: [],
                    environment: [:]
                )),
                timeout: 10,
                dependencies: []
            )
        }

        let config = CheckConfiguration(checks: checks)
        let pr = createTestPR()

        mockFactory.mockResults = checks.map { check in
            CheckResult(
                check: check,
                status: .passed,
                output: "Success",
                startedAt: Date(),
                completedAt: Date(),
                duration: 1.0
            )
        }

        let result = try await useCase.executeChecks(
            for: pr,
            configuration: config
        )

        XCTAssertTrue(result.allPassed)
        XCTAssertEqual(result.results.count, 5)
    }

    func testCaching() async throws {
        let check = createTestCheck()
        let config = CheckConfiguration(checks: [check])
        let pr = createTestPR()

        mockFactory.mockResults = [
            CheckResult(
                check: check,
                status: .passed,
                output: nil,
                startedAt: Date(),
                completedAt: Date(),
                duration: 1.0
            )
        ]

        // First execution
        let result1 = try await useCase.executeChecks(for: pr, configuration: config)
        XCTAssertTrue(result1.allPassed)

        // Second execution should use cache
        mockFactory.mockResults = [] // Clear mock
        let result2 = try await useCase.executeChecks(for: pr, configuration: config)
        XCTAssertTrue(result2.allPassed)
    }
}
```

## Performance Considerations

### Concurrency Tuning

- **maxConcurrentChecks**: Default 5, adjust based on check execution time
- Balance between throughput and resource usage

### Caching Strategy

- Cache by SHA to avoid re-running checks for same code
- Set appropriate expiration time (1 hour default)
- Limit cache size to prevent memory issues

### Fail-Fast Optimization

- Cancel remaining checks when one fails
- Saves time and resources
- Configurable per queue

---

**Related:** 02-github-actions-local-script-implementation.md
