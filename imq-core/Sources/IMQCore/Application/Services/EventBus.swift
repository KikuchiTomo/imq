import Foundation
import Logging

/// Simple pub/sub event bus for internal events
///
/// EventBus provides a thread-safe publish-subscribe mechanism for internal
/// application events. Components can publish events and subscribe to receive
/// notifications when specific events occur.
///
/// Example usage:
/// ```swift
/// let eventBus = EventBus()
///
/// // Subscribe to events
/// let subscription = await eventBus.subscribe { event in
///     switch event {
///     case .queueEntryStarted(let entry):
///         print("Processing started: \(entry.id)")
///     case .checkCompleted(let check, let status):
///         print("Check \(check.name) completed: \(status)")
///     default:
///         break
///     }
/// }
///
/// // Publish an event
/// await eventBus.publish(.queueEntryStarted(entry))
///
/// // Unsubscribe when done
/// await eventBus.unsubscribe(subscription)
/// ```
public actor EventBus: Sendable {
    // MARK: - Types

    /// Event handler function type
    public typealias EventHandler = @Sendable (Event) async -> Void

    /// Subscription identifier
    public struct SubscriptionID: Hashable, Sendable {
        fileprivate let id: UUID

        fileprivate init() {
            self.id = UUID()
        }
    }

    /// Subscription record
    private struct Subscription: Sendable {
        let id: SubscriptionID
        let handler: EventHandler
    }

    // MARK: - Properties

    /// Active subscriptions
    private var subscriptions: [Subscription] = []

    /// Logger for event bus operations
    private let logger: Logger

    /// Statistics
    private var publishedCount: Int = 0
    private var subscriberCount: Int = 0

    // MARK: - Initialization

    /// Creates a new EventBus
    ///
    /// - Parameter logger: Logger for event bus operations
    public init(logger: Logger = Logger(label: "imq.eventbus")) {
        self.logger = logger
    }

    // MARK: - Publishing

    /// Publishes an event to all subscribers
    ///
    /// All subscribed handlers are called concurrently. Errors in handlers
    /// are logged but do not prevent other handlers from executing.
    ///
    /// - Parameter event: The event to publish
    ///
    /// Example:
    /// ```swift
    /// await eventBus.publish(.queueEntryCompleted(entry, .completed))
    /// ```
    public func publish(_ event: Event) async {
        publishedCount += 1

        logger.trace(
            "Publishing event",
            metadata: [
                "event": "\(event.name)",
                "subscribers": "\(subscriptions.count)"
            ]
        )

        // Call all handlers concurrently
        await withTaskGroup(of: Void.self) { group in
            for subscription in subscriptions {
                group.addTask {
                    do {
                        await subscription.handler(event)
                    } catch {
                        self.logger.error(
                            "Event handler error",
                            metadata: [
                                "event": "\(event.name)",
                                "error": "\(error)"
                            ]
                        )
                    }
                }
            }

            await group.waitForAll()
        }
    }

    // MARK: - Subscribing

    /// Subscribes to receive all events
    ///
    /// The provided handler will be called asynchronously whenever an event
    /// is published. Handlers are called concurrently and should be thread-safe.
    ///
    /// - Parameter handler: The event handler function
    /// - Returns: Subscription ID for later unsubscription
    ///
    /// Example:
    /// ```swift
    /// let subscriptionID = await eventBus.subscribe { event in
    ///     print("Received event: \(event.name)")
    /// }
    /// ```
    public func subscribe(_ handler: @escaping EventHandler) -> SubscriptionID {
        let subscription = Subscription(
            id: SubscriptionID(),
            handler: handler
        )

        subscriptions.append(subscription)
        subscriberCount += 1

        logger.debug(
            "New subscriber",
            metadata: [
                "subscriptionID": "\(subscription.id.id)",
                "totalSubscribers": "\(subscriptions.count)"
            ]
        )

        return subscription.id
    }

    /// Unsubscribes from event notifications
    ///
    /// - Parameter subscriptionID: The subscription ID to remove
    ///
    /// Example:
    /// ```swift
    /// await eventBus.unsubscribe(subscriptionID)
    /// ```
    public func unsubscribe(_ subscriptionID: SubscriptionID) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
            subscriptions.remove(at: index)

            logger.debug(
                "Unsubscribed",
                metadata: [
                    "subscriptionID": "\(subscriptionID.id)",
                    "totalSubscribers": "\(subscriptions.count)"
                ]
            )
        }
    }

    /// Removes all subscriptions
    public func unsubscribeAll() {
        let count = subscriptions.count
        subscriptions.removeAll()
        logger.info("Unsubscribed all (\(count) subscribers)")
    }

    // MARK: - Statistics

    /// Returns event bus statistics
    public func statistics() -> EventBusStatistics {
        EventBusStatistics(
            activeSubscribers: subscriptions.count,
            totalPublished: publishedCount,
            totalSubscribers: subscriberCount
        )
    }

    /// Resets statistics counters
    public func resetStatistics() {
        publishedCount = 0
        subscriberCount = subscriptions.count
        logger.debug("Reset event bus statistics")
    }
}

// MARK: - Event Types

/// Application events
public enum Event: Sendable {
    // Queue Entry Events
    case queueEntryStarted(QueueEntry)
    case queueEntryCompleted(QueueEntry, QueueEntryStatus)
    case queueEntryFailed(QueueEntry, Error)
    case queueEntryRemoved(QueueEntry)

    // Check Events
    case checkStarted(Check, QueueEntry)
    case checkCompleted(Check, CheckStatus, TimeInterval)
    case checkFailed(Check, Error)

    // Queue Events
    case queueProcessingStarted(Queue)
    case queueProcessingCompleted(Queue, success: Bool, TimeInterval)
    case queueEmpty(Queue)

    // Merge Events
    case mergeStarted(PullRequest)
    case mergeCompleted(PullRequest)
    case mergeFailed(PullRequest, Error)

    // Conflict Events
    case conflictDetected(PullRequest, conflictsWith: [PullRequest])
    case conflictResolved(PullRequest)

    // System Events
    case processorStarted
    case processorStopped
    case processorShuttingDown

    /// Human-readable event name
    public var name: String {
        switch self {
        case .queueEntryStarted: return "QueueEntryStarted"
        case .queueEntryCompleted: return "QueueEntryCompleted"
        case .queueEntryFailed: return "QueueEntryFailed"
        case .queueEntryRemoved: return "QueueEntryRemoved"
        case .checkStarted: return "CheckStarted"
        case .checkCompleted: return "CheckCompleted"
        case .checkFailed: return "CheckFailed"
        case .queueProcessingStarted: return "QueueProcessingStarted"
        case .queueProcessingCompleted: return "QueueProcessingCompleted"
        case .queueEmpty: return "QueueEmpty"
        case .mergeStarted: return "MergeStarted"
        case .mergeCompleted: return "MergeCompleted"
        case .mergeFailed: return "MergeFailed"
        case .conflictDetected: return "ConflictDetected"
        case .conflictResolved: return "ConflictResolved"
        case .processorStarted: return "ProcessorStarted"
        case .processorStopped: return "ProcessorStopped"
        case .processorShuttingDown: return "ProcessorShuttingDown"
        }
    }
}

// MARK: - Statistics

/// Event bus statistics
public struct EventBusStatistics: Sendable {
    /// Number of active subscribers
    public let activeSubscribers: Int

    /// Total number of events published
    public let totalPublished: Int

    /// Total number of subscribers (including unsubscribed)
    public let totalSubscribers: Int
}

// MARK: - Convenience Extensions

extension EventBus {
    /// Subscribes to specific event types only
    ///
    /// - Parameters:
    ///   - eventTypes: Set of event names to subscribe to
    ///   - handler: Handler to call for matching events
    /// - Returns: Subscription ID
    ///
    /// Example:
    /// ```swift
    /// let subscriptionID = await eventBus.subscribe(
    ///     to: ["CheckCompleted", "CheckFailed"]
    /// ) { event in
    ///     // Only receives check completion events
    /// }
    /// ```
    public func subscribe(
        to eventTypes: Set<String>,
        handler: @escaping EventHandler
    ) -> SubscriptionID {
        subscribe { event in
            if eventTypes.contains(event.name) {
                await handler(event)
            }
        }
    }

    /// Publishes multiple events
    ///
    /// - Parameter events: Array of events to publish
    ///
    /// Example:
    /// ```swift
    /// await eventBus.publishAll([
    ///     .checkCompleted(check1, .passed, 10.0),
    ///     .checkCompleted(check2, .passed, 15.0)
    /// ])
    /// ```
    public func publishAll(_ events: [Event]) async {
        for event in events {
            await publish(event)
        }
    }
}

// MARK: - Event Filtering

extension Event {
    /// Returns true if event is a queue entry event
    public var isQueueEntryEvent: Bool {
        switch self {
        case .queueEntryStarted, .queueEntryCompleted, .queueEntryFailed, .queueEntryRemoved:
            return true
        default:
            return false
        }
    }

    /// Returns true if event is a check event
    public var isCheckEvent: Bool {
        switch self {
        case .checkStarted, .checkCompleted, .checkFailed:
            return true
        default:
            return false
        }
    }

    /// Returns true if event is a merge event
    public var isMergeEvent: Bool {
        switch self {
        case .mergeStarted, .mergeCompleted, .mergeFailed:
            return true
        default:
            return false
        }
    }

    /// Returns true if event is a system event
    public var isSystemEvent: Bool {
        switch self {
        case .processorStarted, .processorStopped, .processorShuttingDown:
            return true
        default:
            return false
        }
    }
}
