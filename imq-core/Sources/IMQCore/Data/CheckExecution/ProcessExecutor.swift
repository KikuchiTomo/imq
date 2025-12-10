import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Helper for executing external processes with timeout support
///
/// Provides cross-platform process execution with:
/// - Timeout handling with graceful termination
/// - Stdout/stderr capture
/// - Environment variable configuration
/// - Proper process cleanup
/// - Signal handling (SIGTERM then SIGKILL)
final class ProcessExecutor: Sendable {

    /// Execute an external process with timeout
    ///
    /// - Parameters:
    ///   - path: Absolute path to the executable
    ///   - arguments: Command line arguments
    ///   - environment: Environment variables to set
    ///   - timeout: Maximum execution time in seconds
    /// - Returns: Process execution result with exit code and output
    /// - Throws: CheckExecutionError if execution fails or times out
    func execute(
        path: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        // Merge environment variables with parent process environment
        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment

        // Setup output pipes for capturing stdout and stderr
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
            // Timeout occurred - attempt graceful termination first
            process.terminate()

            // Wait briefly for graceful termination
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            // Force kill if still running
            if process.isRunning {
                kill(processID, SIGKILL)
            }

            throw CheckExecutionError.processExecutionFailed(
                "Process timed out after \(timeout) seconds"
            )
        }

        // Read output from pipes
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

    // MARK: - Private Helpers

    /// Execute operation with timeout using task racing
    ///
    /// - Parameters:
    ///   - seconds: Timeout duration in seconds
    ///   - operation: Async operation to execute
    /// - Returns: True if operation completed, false if timeout occurred
    /// - Throws: Errors from the operation
    private func withTimeout(
        seconds: TimeInterval,
        operation: @escaping () async -> Void
    ) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            // Task 1: The actual operation
            group.addTask {
                await operation()
                return true
            }

            // Task 2: Timeout timer
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }

            // Race: return result of whichever completes first
            guard let result = try await group.next() else {
                return false
            }

            // Cancel the remaining task
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Process Result

/// Result of a process execution
struct ProcessResult: Sendable {
    /// Exit code from the process (0 typically indicates success)
    let exitCode: Int

    /// Standard output captured from the process
    let stdout: String

    /// Standard error output captured from the process
    let stderr: String
}
