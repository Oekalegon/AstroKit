import AstroKit
import AstrophotoKit
import Foundation
import SQLite3

actor ArchiveDatabase {
    // Tells SQLite to copy the string before the call returns.
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    var db: OpaquePointer?
    let archiveRootPath: String
    let iso = ISO8601DateFormatter()

    init(url: URL, archiveRootPath: String) throws {
        self.archiveRootPath = archiveRootPath
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(url.path, &ptr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database = ptr else {
            throw ArchiveError.databaseError("Cannot open database at \(url.path)")
        }
        db = database
        // Enforce referential integrity so ON DELETE CASCADE/SET NULL work correctly.
        sqlite3_exec(database, "PRAGMA foreign_keys = ON", nil, nil, nil)
        // Apply migrations directly — init has exclusive access to self.
        try ArchiveDatabase.applyMigrations(db: database)
        // Normalize any legacy absolute paths to archive-root-relative paths.
        ArchiveDatabase.normalizeFilePaths(db: database, archiveRootPath: archiveRootPath)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - SQLite helpers

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ArchiveError.databaseError(dbErrorMessage())
        }
        return stmt
    }

    func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errmsg)
            throw ArchiveError.databaseError(msg)
        }
    }

    func scalarInt(_ sql: String) throws -> Int? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func rows(_ sql: String) throws -> [[Any?]] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var result: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = Int(sqlite3_column_count(stmt))
            var row: [Any?] = []
            for col in 0..<n {
                switch sqlite3_column_type(stmt, Int32(col)) {
                case SQLITE_INTEGER: row.append(Int(sqlite3_column_int(stmt, Int32(col))))
                case SQLITE_FLOAT:   row.append(sqlite3_column_double(stmt, Int32(col)))
                case SQLITE_TEXT:    row.append(sqlite3_column_text(stmt, Int32(col)).map { String(cString: $0) })
                default:             row.append(nil)
                }
            }
            result.append(row)
        }
        return result
    }

    func dbErrorMessage() -> String {
        guard let db else { return "Database not open" }
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: - Bind helpers

    func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String) {
        sqlite3_bind_text(stmt, pos, value, -1, Self.sqliteTransient)
    }
    func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String?) {
        if let v = value { sqlite3_bind_text(stmt, pos, v, -1, Self.sqliteTransient) }
        else              { sqlite3_bind_null(stmt, pos) }
    }
    func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Double?) {
        if let v = value { sqlite3_bind_double(stmt, pos, v) }
        else             { sqlite3_bind_null(stmt, pos) }
    }
    func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int64?) {
        if let v = value { sqlite3_bind_int64(stmt, pos, v) }
        else             { sqlite3_bind_null(stmt, pos) }
    }
    func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Data?) {
        guard let v = value else { sqlite3_bind_null(stmt, pos); return }
        _ = v.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, pos, ptr.baseAddress, Int32(v.count), Self.sqliteTransient)
        }
    }

    func bindAny(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Any) {
        switch value {
        case let s as String: sqlite3_bind_text(stmt, pos, s, -1, Self.sqliteTransient)
        case let d as Double: sqlite3_bind_double(stmt, pos, d)
        case let n as Int:    sqlite3_bind_int(stmt, pos, Int32(n))
        case let n as Int64:  sqlite3_bind_int64(stmt, pos, n)
        default: break
        }
    }

    // MARK: - Column helpers

    func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }
    func columnDouble(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, col)
    }
    func columnBlob(_ stmt: OpaquePointer?, _ col: Int32) -> Data? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, col)))
    }
}
