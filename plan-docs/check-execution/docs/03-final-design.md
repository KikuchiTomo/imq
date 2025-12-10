# Check Execution Design - 第3回検討（最終設計）

## 検討日
2025-12-10

## 完全な Check Execution UseCase

```swift
final class ProductionCheckExecutionUseCase: CheckExecutionUseCase {
    private let factory: CheckExecutorFactory
    private let cache: CheckResultCache
    private let githubGateway: GitHubGateway
    private let metrics: CheckMetrics

    func executeChecks(for entry: QueueEntry) async throws -> CheckExecutionResult {
        // 1. Get required checks from GitHub
        let requiredChecks = try await githubGateway.fetchRequiredChecks(
            repository: entry.pullRequest.repository,
            baseBranch: entry.pullRequest.baseBranch
        )

        // 2. Create Check entities
        let checks = requiredChecks.map { req in
            Check(
                id: CheckID(),
                name: req.name,
                type: determineCheckType(req),
                status: .pending,
                configuration: CheckConfiguration.default
            )
        }

        // 3. Execute checks (with cache)
        let results = try await executeChecksWithCache(checks, pullRequest: entry.pullRequest)

        // 4. Record metrics
        for result in results {
            await metrics.recordCheckExecution(result)
        }

        return CheckExecutionResult(
            allPassed: results.allSatisfy { $0.status == .success },
            results: results
        )
    }

    private func executeChecksWithCache(
        _ checks: [Check],
        pullRequest: PullRequest
    ) async throws -> [CheckResult] {
        var results: [CheckResult] = []

        for check in checks {
            // Check cache
            if let cached = await cache.get(check: check, pr: pullRequest) {
                logger.info("Using cached result for check: \(check.name)")
                results.append(cached)
                continue
            }

            // Execute
            let executor = factory.createExecutor(for: check.type)
            let result = try await executor.execute(check: check, pullRequest: pullRequest)

            // Cache successful results
            if case .success = result.status {
                await cache.set(check: check, pr: pullRequest, result: result)
            }

            results.append(result)

            // Fail fast
            if case .failure = result.status {
                break
            }
        }

        return results
    }

    private func determineCheckType(_ required: RequiredCheck) -> CheckType {
        // Heuristic to determine if it's a GitHub Action or local script
        if required.name.contains("/") {
            // Likely a GitHub Action workflow
            return .githubAction(workflowName: required.name, jobName: nil)
        } else {
            // Local script
            return .localScript(scriptPath: "/usr/local/bin/\(required.name)")
        }
    }
}
```

## エラーハンドリング

```swift
enum CheckExecutionError: Error {
    case invalidCheckType
    case timeout
    case cancelled
    case scriptNotFound(path: String)
    case workflowNotFound(name: String)
    case cyclicDependency
}
```

## 実装チェックリスト

- ✅ Check types (GitHub Actions, Local Script, Custom)
- ✅ Check executor protocol
- ✅ GitHub Actions executor with polling
- ✅ Local script executor with process management
- ✅ Check executor factory
- ✅ Parallel execution with semaphore
- ✅ Check dependencies and resolution
- ✅ Check result caching
- ✅ Timeout handling
- ✅ Fail-fast strategy
- ✅ Metrics collection

## 設計完了

Check Execution設計完了。全ての主要機能の設計ドキュメントが完成しました。
