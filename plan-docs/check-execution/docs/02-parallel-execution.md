# Check Execution Design - 第2回検討（並行実行と依存関係）

## 検討日
2025-12-10

## Check並行実行

```swift
final class ParallelCheckExecutionUseCase: CheckExecutionUseCase {
    private let factory: CheckExecutorFactory
    private let maxConcurrentChecks: Int = 5

    func executeChecks(for entry: QueueEntry) async throws -> CheckExecutionResult {
        let checks = try await getRequiredChecks(for: entry)

        return try await withThrowingTaskGroup(of: CheckResult.self) { group in
            var results: [CheckResult] = []
            let semaphore = AsyncSemaphore(value: maxConcurrentChecks)

            for check in checks {
                group.addTask {
                    await semaphore.wait()
                    defer { await semaphore.signal() }

                    let executor = self.factory.createExecutor(for: check.type)
                    return try await executor.execute(check: check, pullRequest: entry.pullRequest)
                }
            }

            for try await result in group {
                results.append(result)

                // Fail fast
                if case .failure = result.status {
                    group.cancelAll()
                    break
                }
            }

            return CheckExecutionResult(
                allPassed: results.allSatisfy { $0.status == .success },
                results: results
            )
        }
    }
}
```

## Check依存関係

```swift
struct CheckDependency {
    let check: Check
    let dependsOn: [CheckID]
}

actor DependencyResolver {
    func executeWithDependencies(_ dependencies: [CheckDependency]) async throws -> [CheckResult] {
        var completed: [CheckID: CheckResult] = [:]
        var pending = dependencies

        while !pending.isEmpty {
            // Find checks with satisfied dependencies
            let ready = pending.filter { dep in
                dep.dependsOn.allSatisfy { completed[$0] != nil }
            }

            guard !ready.isEmpty else {
                throw CheckExecutionError.cyclicDependency
            }

            // Execute ready checks in parallel
            let results = try await withThrowingTaskGroup(of: (CheckID, CheckResult).self) { group in
                for dep in ready {
                    group.addTask {
                        let executor = self.factory.createExecutor(for: dep.check.type)
                        let result = try await executor.execute(check: dep.check, pullRequest: self.pullRequest)
                        return (dep.check.id, result)
                    }
                }

                var results: [(CheckID, CheckResult)] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }

            // Mark as completed
            for (checkID, result) in results {
                completed[checkID] = result
            }

            // Remove from pending
            pending.removeAll { dep in ready.contains(where: { $0.check.id == dep.check.id }) }
        }

        return Array(completed.values)
    }
}
```

## Check結果のキャッシュ

```swift
actor CheckResultCache {
    private var cache: [String: CheckResult] = [:]

    func get(check: Check, pr: PullRequest) -> CheckResult? {
        let key = cacheKey(check: check, pr: pr)
        return cache[key]
    }

    func set(check: Check, pr: PullRequest, result: CheckResult) {
        let key = cacheKey(check: check, pr: pr)
        cache[key] = result
    }

    private func cacheKey(check: Check, pr: PullRequest) -> String {
        "\(check.name)-\(pr.headSHA)"
    }
}
```
