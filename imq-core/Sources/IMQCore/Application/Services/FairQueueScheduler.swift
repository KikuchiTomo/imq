import Foundation
import Logging

/// Fair queue scheduler using Weighted Deficit Round Robin algorithm
///
/// FairQueueScheduler ensures both priority and fairness in queue processing.
/// It uses a weighted deficit round robin algorithm to prevent starvation of
/// lower-priority queues while still giving preference to higher-priority ones.
///
/// Priority is determined by branch name:
/// - Critical: Hotfix branches
/// - High: Release branches
/// - Normal: Main/master branches
/// - Low: Other branches (feature, development, etc.)
///
/// Example usage:
/// ```swift
/// let scheduler = FairQueueScheduler(logger: logger)
///
/// // Add queues to schedule
/// await scheduler.schedule(queue1)
/// await scheduler.schedule(queue2)
///
/// // Get next queue to process
/// if let queue = await scheduler.nextQueue() {
///     // Process this queue
/// }
/// ```
public actor FairQueueScheduler {
    // MARK: - Types

    /// Weighted queue entry for scheduling
    private struct WeightedQueue: Sendable {
        let queue: Queue
        let priority: QueuePriority
        let weight: Int
        var deficit: Int
    }

    // MARK: - Properties

    /// Weighted queues awaiting processing
    private var weightedQueues: [WeightedQueue] = []

    /// Logger for scheduling operations
    private let logger: Logger

    // MARK: - Initialization

    /// Creates a new FairQueueScheduler
    ///
    /// - Parameter logger: Logger for scheduling operations
    public init(logger: Logger = Logger(label: "imq.scheduler")) {
        self.logger = logger
    }

    // MARK: - Public Methods

    /// Schedules a queue for processing
    ///
    /// The queue is added to the scheduler with a priority and weight
    /// determined by its base branch name. Higher priority queues receive
    /// more scheduling weight but lower priority queues are still processed
    /// fairly using the deficit round robin algorithm.
    ///
    /// - Parameter queue: The queue to schedule
    ///
    /// Example:
    /// ```swift
    /// await scheduler.schedule(queue)
    /// ```
    public func schedule(_ queue: Queue) {
        // Skip empty queues
        guard !queue.isEmpty else {
            logger.trace("Skipping empty queue: \(queue.id.value)")
            return
        }

        let priority = determinePriority(for: queue)
        let weight = weightForPriority(priority)

        let weightedQueue = WeightedQueue(
            queue: queue,
            priority: priority,
            weight: weight,
            deficit: 0
        )

        weightedQueues.append(weightedQueue)

        logger.debug(
            "Scheduled queue",
            metadata: [
                "queueID": "\(queue.id.value)",
                "repo": "\(queue.repository.fullName)",
                "branch": "\(queue.baseBranch.value)",
                "priority": "\(priority.rawValue)",
                "weight": "\(weight)",
                "entries": "\(queue.entries.count)"
            ]
        )
    }

    /// Schedules multiple queues
    ///
    /// - Parameter queues: Array of queues to schedule
    public func scheduleAll(_ queues: [Queue]) {
        for queue in queues {
            schedule(queue)
        }
    }

    /// Returns the next queue to process using weighted deficit round robin
    ///
    /// This method implements the Weighted Deficit Round Robin algorithm:
    /// 1. Each queue accumulates a deficit based on its weight
    /// 2. The queue with the highest deficit is selected
    /// 3. Remaining queues accumulate more deficit for the next round
    ///
    /// This ensures fairness while respecting priority weights.
    ///
    /// - Returns: The next queue to process, or nil if no queues are scheduled
    ///
    /// Example:
    /// ```swift
    /// while let queue = await scheduler.nextQueue() {
    ///     await process(queue)
    /// }
    /// ```
    public func nextQueue() -> Queue? {
        guard !weightedQueues.isEmpty else {
            return nil
        }

        // Find queue with highest deficit
        var selectedIndex = 0
        var maxDeficit = weightedQueues[0].deficit

        for (index, wq) in weightedQueues.enumerated() {
            // Break ties by priority
            if wq.deficit > maxDeficit || (wq.deficit == maxDeficit && wq.priority < weightedQueues[selectedIndex].priority) {
                maxDeficit = wq.deficit
                selectedIndex = index
            }
        }

        // Remove selected queue
        let selected = weightedQueues.remove(at: selectedIndex)

        // Update deficits for remaining queues
        for index in weightedQueues.indices {
            weightedQueues[index].deficit += weightedQueues[index].weight
        }

        logger.debug(
            "Selected queue for processing",
            metadata: [
                "queueID": "\(selected.queue.id.value)",
                "priority": "\(selected.priority.rawValue)",
                "deficit": "\(selected.deficit)",
                "remainingQueues": "\(weightedQueues.count)"
            ]
        )

        return selected.queue
    }

    /// Returns the number of queues currently scheduled
    public var count: Int {
        weightedQueues.count
    }

    /// Returns true if no queues are scheduled
    public var isEmpty: Bool {
        weightedQueues.isEmpty
    }

    /// Clears all scheduled queues
    public func clear() {
        let count = weightedQueues.count
        weightedQueues.removeAll()
        logger.debug("Cleared scheduler (\(count) queues)")
    }

    /// Returns summary of scheduled queues by priority
    public func summary() -> SchedulerSummary {
        var countsByPriority: [QueuePriority: Int] = [:]

        for wq in weightedQueues {
            countsByPriority[wq.priority, default: 0] += 1
        }

        return SchedulerSummary(
            totalQueues: weightedQueues.count,
            queuesByPriority: countsByPriority
        )
    }

    // MARK: - Private Methods

    /// Determines priority based on branch name
    ///
    /// Priority determination rules:
    /// - Critical: Branch name contains "hotfix"
    /// - High: Branch name contains "release"
    /// - Normal: Branch is "main" or "master"
    /// - Low: All other branches
    ///
    /// - Parameter queue: The queue to analyze
    /// - Returns: The determined priority
    private func determinePriority(for queue: Queue) -> QueuePriority {
        let baseBranch = queue.baseBranch.value.lowercased()

        if baseBranch.contains("hotfix") {
            return .critical
        } else if baseBranch.contains("release") {
            return .high
        } else if ["main", "master"].contains(baseBranch) {
            return .normal
        } else {
            return .low
        }
    }

    /// Returns scheduling weight for a priority level
    ///
    /// Higher weights mean more frequent scheduling.
    ///
    /// - Parameter priority: The priority level
    /// - Returns: Scheduling weight
    private func weightForPriority(_ priority: QueuePriority) -> Int {
        switch priority {
        case .critical: return 4
        case .high: return 3
        case .normal: return 2
        case .low: return 1
        }
    }
}

// MARK: - Supporting Types

/// Queue priority levels
public enum QueuePriority: Int, Comparable, Sendable {
    case critical = 0  // Hotfix branches
    case high = 1      // Release branches
    case normal = 2    // Main/master
    case low = 3       // Feature branches

    public static func < (lhs: QueuePriority, rhs: QueuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }
}

/// Summary of scheduler state
public struct SchedulerSummary: Sendable {
    /// Total number of queues scheduled
    public let totalQueues: Int

    /// Number of queues by priority
    public let queuesByPriority: [QueuePriority: Int]

    /// Number of critical priority queues
    public var criticalCount: Int {
        queuesByPriority[.critical] ?? 0
    }

    /// Number of high priority queues
    public var highCount: Int {
        queuesByPriority[.high] ?? 0
    }

    /// Number of normal priority queues
    public var normalCount: Int {
        queuesByPriority[.normal] ?? 0
    }

    /// Number of low priority queues
    public var lowCount: Int {
        queuesByPriority[.low] ?? 0
    }
}
