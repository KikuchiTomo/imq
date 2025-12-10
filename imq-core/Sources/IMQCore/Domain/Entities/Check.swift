import Foundation

// MARK: - Check Type

/// Type of check to be executed
///
/// Defines the different types of checks that can be run on a pull request.
/// Each type has different execution requirements and configurations.
public enum CheckType: Codable, Sendable, Equatable {
    /// GitHub Actions workflow check
    case githubActions

    /// Local script execution check
    case localScript

    // MARK: - Coding Keys

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum TypeValue: String, Codable {
        case githubActions
        case localScript
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeValue.self, forKey: .type)

        switch type {
        case .githubActions:
            self = .githubActions
        case .localScript:
            self = .localScript
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .githubActions:
            try container.encode(TypeValue.githubActions, forKey: .type)
        case .localScript:
            try container.encode(TypeValue.localScript, forKey: .type)
        }
    }
}

// MARK: - Check Type Configuration

/// Configuration for different check types
///
/// Provides type-specific configuration for each check type.
/// Each case contains the necessary parameters for that check type.
public enum CheckTypeConfiguration: Codable, Sendable, Equatable {
    /// GitHub Actions workflow configuration
    case githubActions(workflowName: String, jobName: String?)

    /// Local script configuration
    case localScript(scriptPath: String, arguments: [String])

    // MARK: - Coding Keys

    private enum CodingKeys: String, CodingKey {
        case type
        case workflowName
        case jobName
        case scriptPath
        case arguments
    }

    private enum TypeValue: String, Codable {
        case githubActions
        case localScript
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeValue.self, forKey: .type)

        switch type {
        case .githubActions:
            let workflowName = try container.decode(String.self, forKey: .workflowName)
            let jobName = try container.decodeIfPresent(String.self, forKey: .jobName)
            self = .githubActions(workflowName: workflowName, jobName: jobName)

        case .localScript:
            let scriptPath = try container.decode(String.self, forKey: .scriptPath)
            let arguments = try container.decode([String].self, forKey: .arguments)
            self = .localScript(scriptPath: scriptPath, arguments: arguments)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .githubActions(let workflowName, let jobName):
            try container.encode(TypeValue.githubActions, forKey: .type)
            try container.encode(workflowName, forKey: .workflowName)
            try container.encodeIfPresent(jobName, forKey: .jobName)

        case .localScript(let scriptPath, let arguments):
            try container.encode(TypeValue.localScript, forKey: .type)
            try container.encode(scriptPath, forKey: .scriptPath)
            try container.encode(arguments, forKey: .arguments)
        }
    }
}

// MARK: - Check

/// Check entity representing a single check to be executed
///
/// This entity defines a check that must be run on a pull request.
/// It includes the check type, configuration, and execution constraints
/// such as timeout and dependencies.
public struct Check: Codable, Sendable, Identifiable {
    // MARK: - Properties

    /// Unique identifier for the check
    public let id: CheckID

    /// Human-readable name for the check
    public let name: String

    /// Type of check
    public let type: CheckType

    /// Type-specific configuration
    public let configuration: CheckTypeConfiguration

    /// Optional timeout in seconds (nil means no timeout)
    public let timeout: TimeInterval?

    /// IDs of checks that must complete successfully before this check runs
    public let dependencies: [CheckID]

    // MARK: - Initialization

    /// Creates a new Check entity
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the check
    ///   - name: Human-readable name
    ///   - type: Type of check
    ///   - configuration: Type-specific configuration
    ///   - timeout: Optional timeout in seconds
    ///   - dependencies: Check IDs that must complete first
    public init(
        id: CheckID,
        name: String,
        type: CheckType,
        configuration: CheckTypeConfiguration,
        timeout: TimeInterval? = nil,
        dependencies: [CheckID] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.configuration = configuration
        self.timeout = timeout
        self.dependencies = dependencies
    }
}

// MARK: - Equatable

extension Check: Equatable {
    public static func == (lhs: Check, rhs: Check) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension Check: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Computed Properties

extension Check {
    /// Returns true if this check has dependencies
    public var hasDependencies: Bool {
        !dependencies.isEmpty
    }

    /// Returns true if this check has a timeout configured
    public var hasTimeout: Bool {
        timeout != nil
    }
}

// MARK: - Check Configuration

/// Configuration for a set of checks
///
/// Defines the complete check configuration including all checks to run
/// and execution policies such as fail-fast behavior.
public struct CheckConfiguration: Codable, Sendable {
    // MARK: - Properties

    /// List of checks to execute
    public let checks: [Check]

    /// Whether to stop execution immediately when a check fails
    public let failFast: Bool

    // MARK: - Initialization

    /// Creates a new CheckConfiguration
    ///
    /// - Parameters:
    ///   - checks: List of checks to execute
    ///   - failFast: Whether to fail fast on first failure
    public init(
        checks: [Check],
        failFast: Bool = true
    ) {
        self.checks = checks
        self.failFast = failFast
    }
}

// MARK: - Computed Properties

extension CheckConfiguration {
    /// Returns the total number of checks
    public var count: Int {
        checks.count
    }

    /// Returns true if there are no checks configured
    public var isEmpty: Bool {
        checks.isEmpty
    }

    /// Returns checks that have no dependencies (can run immediately)
    public var independentChecks: [Check] {
        checks.filter { !$0.hasDependencies }
    }

    /// Returns checks that have dependencies
    public var dependentChecks: [Check] {
        checks.filter { $0.hasDependencies }
    }

    /// Returns all GitHub Actions checks
    public var githubActionsChecks: [Check] {
        checks.filter { $0.type == .githubActions }
    }

    /// Returns all local script checks
    public var localScriptChecks: [Check] {
        checks.filter { $0.type == .localScript }
    }
}

// MARK: - Validation

extension CheckConfiguration {
    /// Validates the check configuration
    ///
    /// Checks for:
    /// - No duplicate check IDs
    /// - All dependencies reference valid check IDs
    /// - No circular dependencies
    ///
    /// - Returns: True if configuration is valid
    public func validate() -> Bool {
        let checkIDs = Set(checks.map { $0.id })

        // Check for duplicates
        guard checkIDs.count == checks.count else {
            return false
        }

        // Check that all dependencies reference valid checks
        for check in checks {
            for dependencyID in check.dependencies {
                guard checkIDs.contains(dependencyID) else {
                    return false
                }
            }
        }

        // Check for circular dependencies
        guard !hasCircularDependencies() else {
            return false
        }

        return true
    }

    /// Checks if there are circular dependencies in the configuration
    ///
    /// - Returns: True if circular dependencies exist
    private func hasCircularDependencies() -> Bool {
        var visited = Set<CheckID>()
        var recursionStack = Set<CheckID>()

        func hasCycle(_ checkID: CheckID) -> Bool {
            visited.insert(checkID)
            recursionStack.insert(checkID)

            guard let check = checks.first(where: { $0.id == checkID }) else {
                return false
            }

            for dependencyID in check.dependencies {
                if !visited.contains(dependencyID) {
                    if hasCycle(dependencyID) {
                        return true
                    }
                } else if recursionStack.contains(dependencyID) {
                    return true
                }
            }

            recursionStack.remove(checkID)
            return false
        }

        for check in checks {
            if !visited.contains(check.id) {
                if hasCycle(check.id) {
                    return true
                }
            }
        }

        return false
    }

    /// Returns checks in topological order (respecting dependencies)
    ///
    /// - Returns: Array of checks in execution order, or nil if circular dependencies exist
    public func topologicalSort() -> [Check]? {
        guard !hasCircularDependencies() else {
            return nil
        }

        var sorted = [Check]()
        var visited = Set<CheckID>()

        func visit(_ checkID: CheckID) {
            guard !visited.contains(checkID) else { return }
            guard let check = checks.first(where: { $0.id == checkID }) else { return }

            visited.insert(checkID)

            for dependencyID in check.dependencies {
                visit(dependencyID)
            }

            sorted.append(check)
        }

        for check in checks {
            visit(check.id)
        }

        return sorted
    }
}
