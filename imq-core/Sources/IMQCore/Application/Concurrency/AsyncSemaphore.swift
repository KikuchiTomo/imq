import Foundation

/// Actor-based semaphore for controlling concurrent operations
///
/// AsyncSemaphore provides a thread-safe mechanism to limit the number of concurrent
/// operations using async/await. It maintains a count of available permits and
/// automatically suspends tasks when no permits are available.
///
/// Example usage:
/// ```swift
/// let semaphore = AsyncSemaphore(permits: 3)
///
/// await semaphore.wait()  // Acquire permit
/// defer { Task { await semaphore.signal() } }  // Release permit
///
/// // Perform work with limited concurrency
/// await doWork()
/// ```
public actor AsyncSemaphore: Sendable {
    // MARK: - Properties

    /// Number of currently available permits
    private var permits: Int

    /// Maximum number of permits
    private let maxPermits: Int

    /// Queue of waiting continuations
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Initialization

    /// Creates a new AsyncSemaphore with the specified number of permits
    ///
    /// - Parameter permits: Initial number of available permits (must be > 0)
    public init(permits: Int) {
        precondition(permits > 0, "Permits must be greater than 0")
        self.permits = permits
        self.maxPermits = permits
    }

    // MARK: - Public Methods

    /// Acquires a permit, suspending if none are available
    ///
    /// If a permit is available, this method returns immediately.
    /// If no permits are available, the caller is suspended until
    /// another task calls signal().
    ///
    /// Example:
    /// ```swift
    /// await semaphore.wait()
    /// // Permit acquired, proceed with work
    /// ```
    public func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        // No permits available, suspend and wait
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases a permit, potentially resuming a waiting task
    ///
    /// If there are tasks waiting for a permit, the first waiting task
    /// is resumed immediately. Otherwise, the permit count is incremented
    /// (up to the maximum).
    ///
    /// Example:
    /// ```swift
    /// defer { Task { await semaphore.signal() } }
    /// ```
    public func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            permits = min(permits + 1, maxPermits)
        }
    }

    // MARK: - Inspection

    /// Returns the current number of available permits
    ///
    /// This value can change at any time due to concurrent access.
    /// Use for debugging and monitoring purposes only.
    public var availablePermits: Int {
        permits
    }

    /// Returns the number of tasks currently waiting for a permit
    ///
    /// This value can change at any time due to concurrent access.
    /// Use for debugging and monitoring purposes only.
    public var waitingCount: Int {
        waiters.count
    }
}
