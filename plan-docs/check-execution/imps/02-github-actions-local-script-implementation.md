# GitHub Actions and Local Script Executors Implementation

**Document Version:** 1.0
**Created:** 2025-12-10
**Status:** Implementation Ready
**Related Design Docs:**
- `../docs/03-final-design.md` - Check execution strategies

## Overview

Detailed implementation for GitHub Actions workflow triggering and Local Script execution with proper timeout handling, cancellation, and cross-platform compatibility.

## Critical Files to Create

1. `imq-core/Sources/IMQCore/Data/CheckExecution/GitHubActionsCheckExecutor.swift` - GitHub Actions executor
2. `imq-core/Sources/IMQCore/Data/CheckExecution/LocalScriptCheckExecutor.swift` - Local script executor
3. `imq-core/Sources/IMQCore/Data/CheckExecution/ProcessExecutor.swift` - Process management helper

## 1. GitHub Actions Check Executor

**File:** `imq-core/Sources/IMQCore/Data/CheckExecution/GitHubActionsCheckExecutor.swift`

### Implementation

```swift
import Foundation
import Logging

/// Executor for GitHub Actions workflow-based checks
final class GitHubActionsCheckExecutor: CheckExecutor {
    private let githubGateway: GitHubGateway
    private let logger: Logger

    // Configuration
    private let pollingInterval: TimeInterval
    private let maxPollingAttempts: Int

    init(
        githubGateway: GitHubGateway,
        pollingInterval: TimeInterval = 10,
        maxPollingAttempts: Int = 60,
        logger: Logger
    ) {
        self.githubGateway = githubGateway
        self.pollingInterval = pollingInterval
        self.maxPollingAttempts = maxPollingAttempts
        self.logger = logger
    }

    func execute(check: Check, for pullRequest: PullRequest) async throws -> CheckResult {
        guard case .githubActions(let config) = check.configuration else {
            throw CheckExecutionError.invalidConfiguration("Expected GitHub Actions configuration")
        }

        let startTime = Date()

        logger.info("Triggering GitHub Actions workflow",
                   metadata: ["workflow": "\(config.workflowName)",
                             "repo": "\(pullRequest.repository.fullName)",
                             "pr": "\(pullRequest.number)",
                             "sha": "\(pullRequest.headSHA)"])

        // Step 1: Trigger workflow
        let workflowRun = try await triggerWorkflow(
            config: config,
            pullRequest: pullRequest
        )

        logger.debug("Workflow triggered",
                    metadata: ["runID": "\(workflowRun.id)",
                              "status": "\(workflowRun.status)"])

        // Step 2: Poll for completion
        let finalRun = try await pollForCompletion(
            runID: workflowRun.id,
            repository: pullRequest.repository
        )

        let completionTime = Date()
        let duration = completionTime.timeIntervalSince(startTime)

        // Step 3: Determine result
        let status: CheckStatus
        let output: String

        switch finalRun.conclusion {
        case "success":
            status = .passed
            output = "Workflow completed successfully"

        case "failure":
            status = .failed
            output = "Workflow failed"

        case "cancelled":
            status = .cancelled
            output = "Workflow was cancelled"

        case "timed_out":
            status = .timedOut
            output = "Workflow timed out"

        default:
            status = .failed
            output = "Workflow completed with conclusion: \(finalRun.conclusion ?? "unknown")"
        }

        logger.info("GitHub Actions check complete",
                   metadata: ["status": "\(status)",
                             "duration": "\(String(format: "%.2f", duration))s"])

        return CheckResult(
            check: check,
            status: status,
            output: output,
            startedAt: startTime,
            completedAt: completionTime,
            duration: duration
        )
    }

    // MARK: - Private Methods

    private func triggerWorkflow(
        config: GitHubActionsConfig,
        pullRequest: PullRequest
    ) async throws -> WorkflowRun {
        // Trigger workflow using workflow_dispatch or re-run existing workflow
        try await githubGateway.triggerWorkflow(
            owner: pullRequest.repository.owner,
            repo: pullRequest.repository.name,
            workflowName: config.workflowName,
            ref: config.ref ?? pullRequest.headBranch,
            inputs: [
                "pr_number": "\(pullRequest.number)",
                "sha": pullRequest.headSHA
            ]
        )
    }

    private func pollForCompletion(
        runID: Int,
        repository: Repository
    ) async throws -> WorkflowRun {
        var attempts = 0

        while attempts < maxPollingAttempts {
            attempts += 1

            let run = try await githubGateway.getWorkflowRun(
                owner: repository.owner,
                repo: repository.name,
                runID: runID
            )

            logger.debug("Polling workflow run",
                        metadata: ["runID": "\(runID)",
                                  "status": "\(run.status)",
                                  "attempt": "\(attempts)/\(maxPollingAttempts)"])

            // Check if workflow is complete
            if run.status == "completed" {
                return run
            }

            // Adaptive polling: increase interval after 10 attempts
            let interval = attempts > 10 ? pollingInterval * 2 : pollingInterval
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        throw CheckExecutionError.pollingTimeout(
            "Workflow did not complete after \(attempts) attempts"
        )
    }
}

// MARK: - Supporting Types

struct WorkflowRun {
    let id: Int
    let status: String  // "queued", "in_progress", "completed"
    let conclusion: String?  // "success", "failure", "cancelled", "timed_out"
}
```

## 2. Local Script Check Executor

**File:** `imq-core/Sources/IMQCore/Data/CheckExecution/LocalScriptCheckExecutor.swift`

### Implementation

```swift
import Foundation
import Logging

/// Executor for local script-based checks
final class LocalScriptCheckExecutor: CheckExecutor {
    private let processExecutor: ProcessExecutor
    private let logger: Logger

    init(
        processExecutor: ProcessExecutor = ProcessExecutor(),
        logger: Logger
    ) {
        self.processExecutor = processExecutor
        self.logger = logger
    }

    func execute(check: Check, for pullRequest: PullRequest) async throws -> CheckResult {
        guard case .localScript(let config) = check.configuration else {
            throw CheckExecutionError.invalidConfiguration("Expected local script configuration")
        }

        let startTime = Date()

        logger.info("Executing local script",
                   metadata: ["script": "\(config.scriptPath)",
                             "args": "\(config.arguments.joined(separator: " "))",
                             "pr": "\(pullRequest.number)"])

        // Validate script exists and is executable
        try validateScript(path: config.scriptPath)

        // Prepare environment
        var environment = config.environment
        environment["IMQ_PR_NUMBER"] = "\(pullRequest.number)"
        environment["IMQ_PR_SHA"] = pullRequest.headSHA
        environment["IMQ_PR_BASE_BRANCH"] = pullRequest.baseBranch
        environment["IMQ_PR_HEAD_BRANCH"] = pullRequest.headBranch
        environment["IMQ_REPO_OWNER"] = pullRequest.repository.owner
        environment["IMQ_REPO_NAME"] = pullRequest.repository.name

        // Execute script
        let result = try await processExecutor.execute(
            path: config.scriptPath,
            arguments: config.arguments,
            environment: environment,
            timeout: check.timeout ?? 600
        )

        let completionTime = Date()
        let duration = completionTime.timeIntervalSince(startTime)

        // Determine status from exit code
        let status: CheckStatus
        if result.exitCode == 0 {
            status = .passed
        } else {
            status = .failed
        }

        let output = """
        Exit Code: \(result.exitCode)

        STDOUT:
        \(result.stdout)

        STDERR:
        \(result.stderr)
        """

        logger.info("Local script execution complete",
                   metadata: ["status": "\(status)",
                             "exitCode": "\(result.exitCode)",
                             "duration": "\(String(format: "%.2f", duration))s"])

        return CheckResult(
            check: check,
            status: status,
            output: output,
            startedAt: startTime,
            completedAt: completionTime,
            duration: duration
        )
    }

    // MARK: - Private Methods

    private func validateScript(path: String) throws {
        let fileManager = FileManager.default

        // Check if script exists
        guard fileManager.fileExists(atPath: path) else {
            throw CheckExecutionError.scriptNotFound(path)
        }

        // Check if script is executable
        guard fileManager.isExecutableFile(atPath: path) else {
            throw CheckExecutionError.scriptNotExecutable(path)
        }
    }
}

// MARK: - Check Execution Errors

enum CheckExecutionError: Error, LocalizedError {
    case invalidConfiguration(String)
    case scriptNotFound(String)
    case scriptNotExecutable(String)
    case pollingTimeout(String)
    case processExecutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid check configuration: \(message)"
        case .scriptNotFound(let path):
            return "Script not found: \(path)"
        case .scriptNotExecutable(let path):
            return "Script is not executable: \(path)"
        case .pollingTimeout(let message):
            return "Polling timeout: \(message)"
        case .processExecutionFailed(let message):
            return "Process execution failed: \(message)"
        }
    }
}
```

## 3. Process Executor

**File:** `imq-core/Sources/IMQCore/Data/CheckExecution/ProcessExecutor.swift`

### Cross-Platform Implementation

```swift
import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Helper for executing external processes with timeout support
final class ProcessExecutor {

    func execute(
        path: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        // Merge environment variables
        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment

        // Setup output pipes
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Launch process
        try process.run()

        let processID = process.processIdentifier

        // Wait for completion with timeout
        let didComplete = try await withTimeout(seconds: timeout) {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }

        if !didComplete {
            // Timeout occurred, kill process
            process.terminate()

            // Wait a bit for graceful termination
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Force kill if still running
            if process.isRunning {
                kill(processID, SIGKILL)
            }

            throw CheckExecutionError.processExecutionFailed("Process timed out after \(timeout) seconds")
        }

        // Read output
        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return ProcessResult(
            exitCode: Int(process.terminationStatus),
            stdout: stdout,
            stderr: stderr
        )
    }

    // MARK: - Timeout Helper

    private func withTimeout(seconds: TimeInterval, operation: () async -> Void) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }

            guard let result = try await group.next() else {
                return false
            }

            group.cancelAll()
            return result
        }
    }
}

// MARK: - Process Result

struct ProcessResult {
    let exitCode: Int
    let stdout: String
    let stderr: String
}
```

## 4. GitHub Gateway Extensions

**File:** `imq-core/Sources/IMQCore/Domain/Gateways/GitHubGateway.swift` (additions)

### Additional Methods for Workflows

```swift
extension GitHubGateway {
    /// Trigger a workflow dispatch event
    func triggerWorkflow(
        owner: String,
        repo: String,
        workflowName: String,
        ref: String,
        inputs: [String: String]
    ) async throws -> WorkflowRun

    /// Get workflow run details
    func getWorkflowRun(
        owner: String,
        repo: String,
        runID: Int
    ) async throws -> WorkflowRun

    /// Cancel a workflow run
    func cancelWorkflowRun(
        owner: String,
        repo: String,
        runID: Int
    ) async throws
}
```

## 5. Example Check Configurations

### GitHub Actions Check

```swift
let githubActionsCheck = Check(
    id: CheckID(),
    name: "CI Tests",
    type: .githubActions,
    configuration: .githubActions(GitHubActionsConfig(
        workflowName: "ci.yml",
        ref: nil  // Use PR head branch
    )),
    timeout: 1800,  // 30 minutes
    dependencies: []
)
```

### Local Script Check

```swift
let localScriptCheck = Check(
    id: CheckID(),
    name: "Lint",
    type: .localScript,
    configuration: .localScript(LocalScriptConfig(
        scriptPath: "/usr/local/bin/swiftlint",
        arguments: ["lint", "--strict"],
        environment: [
            "LINT_CONFIG": ".swiftlint.yml"
        ]
    )),
    timeout: 300,  // 5 minutes
    dependencies: []
)
```

## Testing Strategy

### Unit Tests for Local Script Executor

```swift
final class LocalScriptExecutorTests: XCTestCase {
    var executor: LocalScriptCheckExecutor!

    override func setUp() {
        executor = LocalScriptCheckExecutor(logger: Logger(label: "test"))
    }

    func testSuccessfulScriptExecution() async throws {
        let check = Check(
            id: CheckID(),
            name: "Test",
            type: .localScript,
            configuration: .localScript(LocalScriptConfig(
                scriptPath: "/bin/echo",
                arguments: ["Hello, World!"],
                environment: [:]
            )),
            timeout: 10,
            dependencies: []
        )

        let pr = createTestPR()
        let result = try await executor.execute(check: check, for: pr)

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.output?.contains("Hello, World!") == true)
    }

    func testScriptTimeout() async throws {
        let check = Check(
            id: CheckID(),
            name: "Slow Script",
            type: .localScript,
            configuration: .localScript(LocalScriptConfig(
                scriptPath: "/bin/sleep",
                arguments: ["10"],
                environment: [:]
            )),
            timeout: 2,  // 2 seconds timeout
            dependencies: []
        )

        let pr = createTestPR()

        do {
            _ = try await executor.execute(check: check, for: pr)
            XCTFail("Expected timeout error")
        } catch {
            // Expected
        }
    }
}
```

## Cross-Platform Considerations

### macOS vs Linux

```swift
#if os(Linux)
// Linux-specific process handling
import Glibc

private func killProcess(_ pid: Int32, signal: Int32) {
    kill(pid, signal)
}
#else
// macOS-specific process handling
import Darwin

private func killProcess(_ pid: Int32, signal: Int32) {
    kill(pid, signal)
}
#endif
```

### File Permissions

```swift
// Check executable permissions on both platforms
extension FileManager {
    func isExecutableFile(atPath path: String) -> Bool {
        #if os(Linux)
        return isExecutableFile(atPath: path)
        #else
        return isExecutableFile(atPath: path)
        #endif
    }
}
```

## Performance Considerations

### GitHub Actions Polling

- Use adaptive polling intervals (10s → 20s after 10 attempts)
- Cache workflow run status
- Implement exponential backoff on failures

### Local Script Execution

- Set appropriate timeouts for different check types
- Limit concurrent local script executions
- Clean up zombie processes

### Resource Management

- Properly close file handles
- Cancel running processes on timeout
- Clean up temporary files

---

**Related:** 01-executor-factory-parallel-execution-implementation.md
