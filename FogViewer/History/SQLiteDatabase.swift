import Foundation
import SQLite3

/// sqlite3 の C API を薄く包んだもの。1 接続を 1 スレッドから使う前提。
final class SQLiteDatabase {
    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private var db: OpaquePointer?

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw Error(message: "\(url.path): \(message)")
        }
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw Error(message: message)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Error(message: "\(String(cString: sqlite3_errmsg(db))) — \(sql)")
        }
        return Statement(stmt: stmt, db: db)
    }

    /// 1 回だけ実行する文。
    func run(_ sql: String, _ values: [Value]) throws {
        let stmt = try prepare(sql)
        try stmt.bind(values)
        try stmt.stepDone()
    }

    enum Value {
        case int(Int64), real(Double), text(String), blob(Data), null

        static func optional(_ d: Data?) -> Value { d.map { .blob($0) } ?? .null }
        static func optional(_ r: Double?) -> Value { r.map { .real($0) } ?? .null }
    }

    final class Statement {
        private let stmt: OpaquePointer
        private let db: OpaquePointer?
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        fileprivate init(stmt: OpaquePointer, db: OpaquePointer?) {
            self.stmt = stmt
            self.db = db
        }

        deinit { sqlite3_finalize(stmt) }

        func bind(_ values: [Value]) throws {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, value) in values.enumerated() {
                let idx = Int32(i + 1)
                let rc: Int32
                switch value {
                case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
                case .real(let v): rc = sqlite3_bind_double(stmt, idx, v)
                case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
                case .blob(let v):
                    rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
                case .null: rc = sqlite3_bind_null(stmt, idx)
                }
                guard rc == SQLITE_OK else { throw Error(message: String(cString: sqlite3_errmsg(db))) }
            }
        }

        /// 行を返さない文を最後まで実行する。
        func stepDone() throws {
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw Error(message: String(cString: sqlite3_errmsg(db)))
            }
        }

        /// 次の行があれば true。
        func step() throws -> Bool {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw Error(message: String(cString: sqlite3_errmsg(db)))
            }
        }

        func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
        func real(_ col: Int32) -> Double? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
        }
        func text(_ col: Int32) -> String? {
            sqlite3_column_text(stmt, col).map { String(cString: $0) }
        }
        func blob(_ col: Int32) -> Data? {
            guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
            let n = Int(sqlite3_column_bytes(stmt, col))
            guard n > 0, let p = sqlite3_column_blob(stmt, col) else { return Data() }
            return Data(bytes: p, count: n)
        }
    }
}
