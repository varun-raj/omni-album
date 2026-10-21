//
//  SQLiteDatabase.swift
//  OmniAlbum
//
//  A thin wrapper over the system SQLite (no dependency). Prepared statements inside one
//  transaction are what make 100k-row syncs fast.
//

import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class SQLiteDatabase {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SQLiteError(message: "open failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA foreign_keys = OFF")
    }

    deinit { sqlite3_close_v2(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(message: "\(message) in: \(sql)")
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "prepare failed: \(String(cString: sqlite3_errmsg(db))) in: \(sql)")
        }
        return SQLiteStatement(stmt, db: db)
    }

    /// All-or-nothing: a failure rolls back, so a half-applied sync batch never reaches disk.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(_ stmt: OpaquePointer, db: OpaquePointer?) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    /// Binds positionally from 1. nil binds NULL.
    func bind(_ values: [Any?]) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ values: [Any?] = []) throws {
        bind(values)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError(message: "step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Steps once; true while a row is available.
    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }

    func text(_ col: Int32) -> String? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, col).map { String(cString: $0) }
    }
    func int(_ col: Int32) -> Int? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, col))
    }
    func double(_ col: Int32) -> Double? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
    }
    func bool(_ col: Int32) -> Bool { sqlite3_column_int(stmt, col) != 0 }
}
