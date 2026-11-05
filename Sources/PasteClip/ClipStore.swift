import CryptoKit
import Foundation
import SQLite3

/// One row as shown in the panel list. The full text is loaded only when pasting.
struct Clip: Equatable {
    let id: Int64
    let preview: String
    let link: URL?
}

enum ClipList {
    case history
    case trash
}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

/// SQLite-backed clip history. Queries are small and indexed, so they run synchronously
/// on the main actor and feed `NSTableView` paging directly.
final class ClipStore {
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let previewLength = 200

    private let db: OpaquePointer
    // SQLITE_TRANSIENT: SQLite copies bound text and blobs before the call returns.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // The store lives for the whole process, so the connection is never closed explicitly.
    init(url: URL) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS clips (
                id INTEGER PRIMARY KEY,
                text TEXT NOT NULL,
                hash BLOB NOT NULL,
                preview TEXT NOT NULL,
                link TEXT,
                used_at REAL NOT NULL,
                deleted_at REAL
            );
            CREATE INDEX IF NOT EXISTS clips_history ON clips(used_at) WHERE deleted_at IS NULL;
            CREATE INDEX IF NOT EXISTS clips_trash ON clips(deleted_at) WHERE deleted_at IS NOT NULL;
            CREATE UNIQUE INDEX IF NOT EXISTS clips_history_hash ON clips(hash) WHERE deleted_at IS NULL;
            CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts
                USING fts5(text, content = 'clips', content_rowid = 'id', tokenize = 'trigram');
            CREATE TRIGGER IF NOT EXISTS clips_after_insert AFTER INSERT ON clips BEGIN
                INSERT INTO clips_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS clips_after_delete AFTER DELETE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            """)
    }

    // MARK: - Writes

    /// Adds `text` to the top of the history. Text already in the history moves to the top instead.
    /// `usedAt` lets imports keep their original order; an existing clip never moves back in time.
    func record(_ text: String, usedAt: Date = Date()) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preview = trimmed.prefix(Self.previewLength * 4)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(Self.previewLength)
        try run("""
            INSERT INTO clips (text, hash, preview, link, used_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (hash) WHERE deleted_at IS NULL DO UPDATE SET used_at = max(used_at, excluded.used_at)
            """,
            .text(text), .blob(Data(SHA256.hash(data: Data(text.utf8)))), .text(String(preview)),
            Link.webURL(in: trimmed).map { .text($0.absoluteString) } ?? .null, .real(usedAt.timeIntervalSince1970))
    }

    func moveToTrash(_ id: Int64) throws {
        try run("UPDATE clips SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", .real(now()), .int(id))
    }

    /// Moves a trashed clip back to the top of the history. If the same text was copied again
    /// meanwhile, the history copy moves to the top and the trashed copy is dropped.
    func restore(_ id: Int64) throws {
        try transaction {
            try run("""
                UPDATE clips SET used_at = ?
                WHERE deleted_at IS NULL AND hash = (SELECT hash FROM clips WHERE id = ? AND deleted_at IS NOT NULL)
                """, .real(now()), .int(id))
            if sqlite3_changes(db) > 0 {
                try run("DELETE FROM clips WHERE id = ?", .int(id))
            } else {
                try run("UPDATE clips SET deleted_at = NULL, used_at = ? WHERE id = ?", .real(now()), .int(id))
            }
        }
    }

    func deletePermanently(_ id: Int64) throws {
        try run("DELETE FROM clips WHERE id = ? AND deleted_at IS NOT NULL", .int(id))
    }

    func emptyTrash() throws {
        try run("DELETE FROM clips WHERE deleted_at IS NOT NULL")
    }

    func purgeExpiredTrash() throws {
        try run("DELETE FROM clips WHERE deleted_at < ?", .real(now() - Self.trashRetention))
    }

    // MARK: - Reads

    func count(in list: ClipList, matching query: String) throws -> Int {
        let (filter, values) = Self.filter(list, query)
        var count = 0
        try run("SELECT count(*) FROM clips WHERE \(filter)", values) { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    func clips(in list: ClipList, matching query: String, offset: Int, limit: Int) throws -> [Clip] {
        let (filter, values) = Self.filter(list, query)
        let order = list == .history ? "used_at" : "deleted_at"
        var clips: [Clip] = []
        clips.reserveCapacity(limit)
        try run(
            "SELECT id, preview, link FROM clips WHERE \(filter) ORDER BY \(order) DESC LIMIT ? OFFSET ?",
            values + [.int(Int64(limit)), .int(Int64(offset))]
        ) { statement in
            clips.append(Clip(
                id: sqlite3_column_int64(statement, 0),
                preview: Self.string(statement, 1) ?? "",
                link: Self.string(statement, 2).flatMap(URL.init(string:))
            ))
        }
        return clips
    }

    func text(of id: Int64) throws -> String? {
        var text: String?
        try run("SELECT text FROM clips WHERE id = ?", [.int(id)]) { text = Self.string($0, 0) }
        return text
    }

    /// Trigram search needs at least three characters; shorter queries fall back to a substring scan.
    private static func filter(_ list: ClipList, _ query: String) -> (String, [Value]) {
        let listFilter = list == .history ? "deleted_at IS NULL" : "deleted_at IS NOT NULL"
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return (listFilter, [])
        }
        if query.unicodeScalars.count >= 3 {
            let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return ("\(listFilter) AND id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)", [.text(phrase)])
        }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return ("\(listFilter) AND text LIKE ? ESCAPE '\\'", [.text("%\(escaped)%")])
    }

    // MARK: - SQLite helpers

    private enum Value {
        case int(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case null
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ values: Value...) throws {
        try run(sql, values, row: nil)
    }

    private func run(_ sql: String, _ values: [Value], row: ((OpaquePointer) -> Void)?) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc = switch value {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            // An explicit byte length keeps text containing NUL characters intact.
            case .text(let value): sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), transient)
            case .blob(let value):
                value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
            guard rc == SQLITE_OK else { throw lastError() }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(statement)
            case SQLITE_DONE: return
            default: throw lastError()
            }
        }
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }
}
