# Check Execution Design - 第1回検討（Check Types）

## 検討日
2025-12-10

## Check の種類

### 1. GitHub Actions Check

```swift
enum CheckType {
    case githubAction(workflowName: String, jobName: String?)
    case localScript(scriptPath: String)
    case custom(executorName: String, config: [String: Any])
}
```

### 2. Check Executor Protocol

```swift
protocol CheckExecutor {
    func execute(check: Check, pullRequest: PullRequest) async throws -> CheckResult
    func cancel(check: Check) async throws
}

struct CheckResult {
    let checkID: CheckID
    let status: CheckStatus
    let output: CheckOutput?
    let duration: TimeInterval
}

struct CheckOutput {
    let stdout: String?
    let stderr: String?
    let exitCode: Int?
    let logs: [LogEntry]?
}
```

### 3. GitHub Actions Executor

```swift
final class GitHubActionsCheckExecutor: CheckExecutor {
    private let githubGateway: GitHubGateway

    func execute(check: Check, pullRequest: PullRequest) async throws -> CheckResult {
        guard case .githubAction(let workflowName, _) = check.type else {
            throw CheckExecutionError.invalidCheckType
        }

        // 1. Trigger workflow
        let run = try await githubGateway.triggerWorkflow(
            repository: pullRequest.repository,
            workflowName: workflowName,
            ref: pullRequest.headBranch,
            inputs: [
                "pr_number": "\(pullRequest.number)",
                "head_sha": pullRequest.headSHA
            ]
        )

        // 2. Poll for completion
        let result = try await pollWorkflowRun(
            repository: pullRequest.repository,
            runID: run.id,
            timeout: check.configuration.timeout
        )

        return result
    }

    private func pollWorkflowRun(
        repository: Repository,
        runID: Int,
        timeout: TimeInterval
    ) async throws -> CheckResult {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let status = try await githubGateway.getWorkflowRunStatus(
                repository: repository,
                runID: runID
            )

            switch status {
            case .completed(let conclusion):
                return CheckResult(
                    checkID: CheckID(),
                    status: conclusion == .success ? .success : .failure(message: "Workflow failed"),
                    output: nil,
                    duration: Date().timeIntervalSince(startTime)
                )
            case .inProgress, .queued:
                try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
            case .cancelled:
                throw CheckExecutionError.cancelled
            }
        }

        throw CheckExecutionError.timeout
    }
}
```

### 4. Local Script Executor

```swift
final class LocalScriptCheckExecutor: CheckExecutor {
    func execute(check: Check, pullRequest: PullRequest) async throws -> CheckResult {
        guard case .localScript(let scriptPath) = check.type else {
            throw CheckExecutionError.invalidCheckType
        }

        let environment = check.configuration.environment.merging([
            "PR_NUMBER": "\(pullRequest.number)",
            "PR_HEAD_SHA": pullRequest.headSHA,
            "PR_BASE_BRANCH": pullRequest.baseBranch,
            "PR_HEAD_BRANCH": pullRequest.headBranch,
            "REPOSITORY": pullRequest.repository.fullName
        ]) { _, new in new }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startTime = Date()

        try process.run()

        // Timeout handling
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(check.configuration.timeout * 1_000_000_000))
            process.terminate()
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return CheckResult(
            checkID: check.id,
            status: process.terminationStatus == 0 ? .success : .failure(message: stderr),
            output: CheckOutput(stdout: stdout, stderr: stderr, exitCode: Int(process.terminationStatus), logs: nil),
            duration: Date().timeIntervalSince(startTime)
        )
    }
}
```

### 5. Check Executor Factory

```swift
protocol CheckExecutorFactory {
    func createExecutor(for type: CheckType) -> CheckExecutor
}

final class CheckExecutorFactoryImpl: CheckExecutorFactory {
    private let githubGateway: GitHubGateway

    func createExecutor(for type: CheckType) -> CheckExecutor {
        switch type {
        case .githubAction:
            return GitHubActionsCheckExecutor(githubGateway: githubGateway)
        case .localScript:
            return LocalScriptCheckExecutor()
        case .custom(let name, _):
            // Load custom executor from plugin
            fatalError("Custom executor '\(name)' not implemented")
        }
    }
}
```

## 次回検討事項
- Check並行実行
- Check依存関係
- Check結果のキャッシュ
