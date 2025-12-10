import Foundation
import Logging

/// Retry policy with exponential backoff
///
/// RetryPolicy provides configurable retry logic with exponential backoff
/// for transient failures. It automatically retries operations that throw
/// errors, with increasing delays between attempts.
///
/// Example usage:
/// ```swift
/// let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1.0)
///
/// let result = try await policy.execute {
///     try await unstableOperation()
/// }
/// ```
public struct RetryPolicy: Sendable {
    // MARK: - Properties

    /// Maximum number of retry attempts
    public let maxAttempts: Int

    /// Base delay in seconds (first retry delay)
    public let baseDelay: TimeInterval

    /// Maximum delay in seconds (cap for exponential backoff)
    public let maxDelay: TimeInterval

    /// Multiplier for exponential backoff
    public let multiplier: Double

    /// Jitter factor (0.0 to 1.0) to randomize delays
    public let jitter: Double

    // MARK: - Initialization

    /// Creates a new RetryPolicy with the specified parameters
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (including initial try)
    ///   - baseDelay: Initial delay in seconds between retries
    ///   - maxDelay: Maximum delay in seconds (cap for exponential backoff)
    ///   - multiplier: Exponential backoff multiplier (default: 2.0)
    ///   - jitter: Random jitter factor 0.0-1.0 (default: 0.1)
    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        multiplier: Double = 2.0,
        jitter: Double = 0.1
    ) {
        precondition(maxAttempts > 0, "Max attempts must be greater than 0")
        precondition(baseDelay > 0, "Base delay must be greater than 0")
        precondition(maxDelay >= baseDelay, "Max delay must be >= base delay")
        precondition(multiplier > 1.0, "Multiplier must be greater than 1.0")
        precondition(jitter >= 0 && jitter <= 1.0, "Jitter must be between 0.0 and 1.0")

        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitter = jitter
    }

    // MARK: - Public Methods

    /// Executes an operation with automatic retry on failure
    ///
    /// The operation is attempted up to `maxAttempts` times. Between attempts,
    /// the policy waits with exponential backoff and optional jitter.
    ///
    /// - Parameter operation: The async throwing operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The last error encountered if all attempts fail
    ///
    /// Example:
    /// ```swift
    /// let result = try await policy.execute {
    ///     try await fetchData()
    /// }
    /// ```
    public func execute<T>(
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var attempt = 1

        while attempt <= maxAttempts {
            do {
                let result = try await operation()
                return result
            } catch {
                lastError = error

                // Don't retry if this was the last attempt
                guard attempt < maxAttempts else {
                    break
                }

                // Calculate delay with exponential backoff
                let delay = calculateDelay(for: attempt)

                // Wait before retrying
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                attempt += 1
            }
        }

        // All attempts failed, throw the last error
        throw RetryError.allAttemptsFailed(
            attempts: maxAttempts,
            lastError: lastError ?? RetryError.unknownError
        )
    }

    /// Executes an operation with automatic retry and logging
    ///
    /// Same as `execute()` but with integrated logging for each retry attempt.
    ///
    /// - Parameters:
    ///   - logger: Logger to use for retry logging
    ///   - operation: The async throwing operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The last error encountered if all attempts fail
    public func execute<T>(
        logger: Logger,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var attempt = 1

        while attempt <= maxAttempts {
            do {
                if attempt > 1 {
                    logger.info("Retry attempt \(attempt)/\(maxAttempts)")
                }

                let result = try await operation()

                if attempt > 1 {
                    logger.info("Operation succeeded on attempt \(attempt)")
                }

                return result
            } catch {
                lastError = error

                // Log the failure
                if attempt < maxAttempts {
                    let delay = calculateDelay(for: attempt)
                    logger.warning(
                        "Operation failed on attempt \(attempt)/\(maxAttempts), retrying in \(String(format: "%.2f", delay))s",
                        metadata: ["error": "\(error)"]
                    )
                } else {
                    logger.error(
                        "Operation failed on final attempt \(attempt)/\(maxAttempts)",
                        metadata: ["error": "\(error)"]
                    )
                }

                // Don't retry if this was the last attempt
                guard attempt < maxAttempts else {
                    break
                }

                // Calculate delay with exponential backoff
                let delay = calculateDelay(for: attempt)

                // Wait before retrying
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                attempt += 1
            }
        }

        // All attempts failed, throw the last error
        throw RetryError.allAttemptsFailed(
            attempts: maxAttempts,
            lastError: lastError ?? RetryError.unknownError
        )
    }

    // MARK: - Private Methods

    /// Calculates the delay for a given attempt with exponential backoff and jitter
    ///
    /// - Parameter attempt: The attempt number (1-based)
    /// - Returns: Delay in seconds
    private func calculateDelay(for attempt: Int) -> TimeInterval {
        // Calculate exponential backoff: baseDelay * (multiplier ^ (attempt - 1))
        let exponentialDelay = baseDelay * pow(multiplier, Double(attempt - 1))

        // Cap at max delay
        let cappedDelay = min(exponentialDelay, maxDelay)

        // Add jitter: random value between (1 - jitter) and (1 + jitter)
        let jitterRange = cappedDelay * jitter
        let randomJitter = Double.random(in: -jitterRange...jitterRange)
        let finalDelay = cappedDelay + randomJitter

        return max(0, finalDelay)
    }
}

// MARK: - Error Types

/// Retry policy errors
public enum RetryError: Error, LocalizedError {
    /// All retry attempts failed
    case allAttemptsFailed(attempts: Int, lastError: Error)

    /// Unknown error occurred
    case unknownError

    public var errorDescription: String? {
        switch self {
        case .allAttemptsFailed(let attempts, let lastError):
            return "Operation failed after \(attempts) attempts. Last error: \(lastError.localizedDescription)"
        case .unknownError:
            return "Unknown error occurred during retry"
        }
    }
}

// MARK: - Predefined Policies

extension RetryPolicy {
    /// Conservative retry policy: 3 attempts, 1s base delay, 30s max delay
    public static let conservative = RetryPolicy(
        maxAttempts: 3,
        baseDelay: 1.0,
        maxDelay: 30.0
    )

    /// Aggressive retry policy: 5 attempts, 0.5s base delay, 60s max delay
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        baseDelay: 0.5,
        maxDelay: 60.0
    )

    /// No retry policy: only 1 attempt
    public static let none = RetryPolicy(
        maxAttempts: 1,
        baseDelay: 0,
        maxDelay: 0
    )
}
