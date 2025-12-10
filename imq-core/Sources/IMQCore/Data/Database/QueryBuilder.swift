import Foundation
import SQLite

/// Protocol for tables that can be queried
protocol TableRepresentable {
    static var tableName: String { get }
    static func columnName<V>(for keyPath: KeyPath<Self, V>) -> String
}

/// Type-safe query builder for SQLite
struct Query<T: TableRepresentable> {
    private var tableName: String
    private var conditions: [Condition] = []
    private var orderByClause: [OrderBy] = []
    private var limitValue: Int?
    private var offsetValue: Int?
    private var selectColumns: [String]?

    init(table: T.Type) {
        self.tableName = T.tableName
    }

    // MARK: - Query Building

    /// Add WHERE condition
    func `where`<V: SQLiteConvertible>(
        _ keyPath: KeyPath<T, V>,
        _ op: ComparisonOperator,
        _ value: V
    ) -> Query<T> {
        var query = self
        let columnName = T.columnName(for: keyPath)
        query.conditions.append(Condition(
            column: columnName,
            operator: op,
            value: value.sqliteValue
        ))
        return query
    }

    /// Add AND condition
    func and<V: SQLiteConvertible>(
        _ keyPath: KeyPath<T, V>,
        _ op: ComparisonOperator,
        _ value: V
    ) -> Query<T> {
        return self.where(keyPath, op, value)
    }

    /// Add ORDER BY clause
    func orderBy<V>(
        _ keyPath: KeyPath<T, V>,
        _ direction: OrderDirection = .ascending
    ) -> Query<T> {
        var query = self
        let columnName = T.columnName(for: keyPath)
        query.orderByClause.append(OrderBy(
            column: columnName,
            direction: direction
        ))
        return query
    }

    /// Add LIMIT clause
    func limit(_ value: Int) -> Query<T> {
        var query = self
        query.limitValue = value
        return query
    }

    /// Add OFFSET clause
    func offset(_ value: Int) -> Query<T> {
        var query = self
        query.offsetValue = value
        return query
    }

    /// Select specific columns
    func select(_ columns: String...) -> Query<T> {
        var query = self
        query.selectColumns = columns
        return query
    }

    // MARK: - SQL Generation

    /// Build SELECT SQL statement
    func buildSelectSQL() -> (sql: String, bindings: [Binding]) {
        var sql = "SELECT "

        if let columns = selectColumns {
            sql += columns.joined(separator: ", ")
        } else {
            sql += "*"
        }

        sql += " FROM \(tableName)"

        var bindings: [Binding] = []

        // WHERE clause
        if !conditions.isEmpty {
            let conditionStrings = conditions.map { condition in
                "\(condition.column) \(condition.operator.symbol) ?"
            }
            sql += " WHERE " + conditionStrings.joined(separator: " AND ")
            bindings.append(contentsOf: conditions.map { $0.value })
        }

        // ORDER BY clause
        if !orderByClause.isEmpty {
            let orderStrings = orderByClause.map { order in
                "\(order.column) \(order.direction.rawValue)"
            }
            sql += " ORDER BY " + orderStrings.joined(separator: ", ")
        }

        // LIMIT clause
        if let limit = limitValue {
            sql += " LIMIT \(limit)"
        }

        // OFFSET clause
        if let offset = offsetValue {
            sql += " OFFSET \(offset)"
        }

        return (sql, bindings)
    }

    /// Build INSERT SQL statement
    func buildInsertSQL(values: [String: Binding]) -> (sql: String, bindings: [Binding]) {
        let columns = values.keys.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")

        let sql = "INSERT INTO \(tableName) (\(columns)) VALUES (\(placeholders))"
        let bindings = Array(values.values)

        return (sql, bindings)
    }

    /// Build UPDATE SQL statement
    func buildUpdateSQL(values: [String: Binding]) -> (sql: String, bindings: [Binding]) {
        let setClause = values.keys.map { "\($0) = ?" }.joined(separator: ", ")
        var sql = "UPDATE \(tableName) SET \(setClause)"

        var bindings = Array(values.values)

        // WHERE clause
        if !conditions.isEmpty {
            let conditionStrings = conditions.map { condition in
                "\(condition.column) \(condition.operator.symbol) ?"
            }
            sql += " WHERE " + conditionStrings.joined(separator: " AND ")
            bindings.append(contentsOf: conditions.map { $0.value })
        }

        return (sql, bindings)
    }

    /// Build DELETE SQL statement
    func buildDeleteSQL() -> (sql: String, bindings: [Binding]) {
        var sql = "DELETE FROM \(tableName)"
        var bindings: [Binding] = []

        // WHERE clause
        if !conditions.isEmpty {
            let conditionStrings = conditions.map { condition in
                "\(condition.column) \(condition.operator.symbol) ?"
            }
            sql += " WHERE " + conditionStrings.joined(separator: " AND ")
            bindings.append(contentsOf: conditions.map { $0.value })
        }

        return (sql, bindings)
    }
}

// MARK: - Supporting Types

protocol SQLiteConvertible {
    var sqliteValue: Binding { get }
}

extension String: SQLiteConvertible {
    var sqliteValue: Binding { self }
}

extension Int: SQLiteConvertible {
    var sqliteValue: Binding { Int64(self) }
}

extension Double: SQLiteConvertible {
    var sqliteValue: Binding { self }
}

extension Bool: SQLiteConvertible {
    var sqliteValue: Binding { self ? 1 : 0 }
}

enum ComparisonOperator {
    case equals
    case notEquals
    case greaterThan
    case lessThan
    case greaterThanOrEquals
    case lessThanOrEquals
    case like
    case `in`

    var symbol: String {
        switch self {
        case .equals: return "="
        case .notEquals: return "!="
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .greaterThanOrEquals: return ">="
        case .lessThanOrEquals: return "<="
        case .like: return "LIKE"
        case .in: return "IN"
        }
    }
}

enum OrderDirection: String {
    case ascending = "ASC"
    case descending = "DESC"
}

struct Condition {
    let column: String
    let `operator`: ComparisonOperator
    let value: Binding
}

struct OrderBy {
    let column: String
    let direction: OrderDirection
}
