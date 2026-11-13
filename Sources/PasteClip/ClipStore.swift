import CryptoKit
import Foundation
import SQLite3
import AppKit

/// One row as shown in the panel list. The full text is loaded only when pasting or previewing.
struct Clip: Equatable {
    let id: Int64
    let preview: String
    let link: URL?
    /// The one-line preview leaves out text: line breaks or anything past the preview length.
    let isAbridged: Bool
    /// nil for a text clip; the SHA256 of the stored PNG for an image clip.
    let image: Data?
    let imageSize: CGSize?
    /// When the clip was moved to the trash; nil in the history.
    let deletedAt: Date?
    /// One line of text around the first search match, starting with "…" when it doesn't start
    /// at the beginning; nil without a search or when the match position is unknown.
    let matchExcerpt: String?
}

enum ClipList {
    case history
    case trash
}

/// What gets written back to the pasteboard when a clip is activated.
enum ClipContent {
    case text(String)
    case image(Data, CGSize)
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
    /// Characters kept before a search match in a row excerpt, and the excerpt's total length.
    private static let matchLead = 12
    private static let excerptLength = 160

    private let db: OpaquePointer
    private let images: ImageStorage
    private let imagesCache = ImageThumbnailCache()
    // SQLITE_TRANSIENT: SQLite copies bound text and blobs before the call returns.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // The store lives for the whole process, so the connection is never closed explicitly.
    init(url: URL, images: ImageStorage) throws {
        self.images = images
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
                kind INTEGER NOT NULL DEFAULT 0,
                image BLOB,
                image_width INTEGER,
                image_height INTEGER,
                used_at REAL NOT NULL,
                deleted_at REAL
            );
            """)
        try migrate()
        try exec("""
            CREATE INDEX IF NOT EXISTS clips_history ON clips(used_at) WHERE deleted_at IS NULL;
            CREATE INDEX IF NOT EXISTS clips_trash ON clips(deleted_at) WHERE deleted_at IS NOT NULL;
            DROP INDEX IF EXISTS clips_history_hash;
            CREATE UNIQUE INDEX clips_history_hash ON clips(kind, hash) WHERE deleted_at IS NULL;
            CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts
                USING fts5(text, content = 'clips', content_rowid = 'id', tokenize = 'trigram');
            """)
        // The FTS table is created before the triggers, so existing text clips need indexing.
        // Dropping and recreating the triggers first keeps a legacy pair from deleting rows
        // that the rebuild has just indexed.
        try exec("""
            DROP TRIGGER IF EXISTS clips_after_insert;
            DROP TRIGGER IF EXISTS clips_after_delete;
            """)
        try rebuildFTSIfNeeded()
        try exec("""
            CREATE TRIGGER IF NOT EXISTS clips_after_insert AFTER INSERT ON clips BEGIN
                INSERT INTO clips_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS clips_after_delete AFTER DELETE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            """)
        try pruneImageFiles()
    }

    /// Databases from before image support lack the four image columns.
    private func migrate() throws {
        var columns: Set<String> = []
        try run("PRAGMA table_info(clips)", [], row: { statement in
            if let name = Self.string(statement, 1) { columns.insert(name) }
        })
        for (name, type) in [
            ("kind", "INTEGER NOT NULL DEFAULT 0"),
            ("image", "BLOB"), ("image_width", "INTEGER"), ("image_height", "INTEGER"),
        ] where !columns.contains(name) {
            try exec("ALTER TABLE clips ADD COLUMN \(name) \(type)")
        }
    }

    /// An FTS table created by an older build may miss text or image rows. `rebuild` reads
    /// the content table directly, so it only needs to run once per schema version.
    private func rebuildFTSIfNeeded() throws {
        var version = 0
        try run("PRAGMA user_version", [], row: { version = Int(sqlite3_column_int64($0, 0)) })
        var terms = 0
        try run("SELECT count(*) FROM clips_fts_idx", [], row: { terms = Int(sqlite3_column_int64($0, 0)) })
        var indexable = 0
        try run("SELECT count(*) FROM clips WHERE length(text) >= 3", [], row: { indexable = Int(sqlite3_column_int64($0, 0)) })
        // A database with only short texts also has an empty trigram index, so only
        // rebuild when there is something to index.
        if indexable > 0 && (terms == 0 || version < 1) {
            try exec("INSERT INTO clips_fts(clips_fts) VALUES ('rebuild')")
            sqlite3_db_release_memory(db)
        }
        if version < 1 {
            try exec("PRAGMA user_version = 1")
        }
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
            ON CONFLICT (kind, hash) WHERE deleted_at IS NULL DO UPDATE SET used_at = max(used_at, excluded.used_at)
            """,
            .text(text), .blob(Data(SHA256.hash(data: Data(text.utf8)))), .text(String(preview)),
            Link.webURL(in: trimmed).map { .text($0.absoluteString) } ?? .null, .real(usedAt.timeIntervalSince1970))
    }

    /// Adds a copied image to the top of the history. The original PNG is written once and
    /// shared by any later clip with the same bytes, including one in the trash.
    func record(_ image: ClipImage, thumbnail: Data? = nil, thumbnailSize: CGSize = .zero, usedAt: Date = Date()) throws {
        let digest = try images.store(image, thumbnail: thumbnail, thumbnailSize: thumbnailSize)
        let preview = image.searchText
        try run("""
            INSERT INTO clips (text, hash, preview, link, kind, image, image_width, image_height, used_at)
            VALUES (?, ?, ?, NULL, 1, ?, ?, ?, ?)
            ON CONFLICT (kind, hash) WHERE deleted_at IS NULL DO UPDATE SET used_at = max(used_at, excluded.used_at)
            """,
            .text(preview), .blob(digest), .text(preview), .blob(digest),
            .int(Int64(image.width)), .int(Int64(image.height)), .real(usedAt.timeIntervalSince1970))
        // A duplicate leaves the newly written file unreferenced; it is cleaned at launch.
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
                WHERE deleted_at IS NULL
                  AND (kind, hash) = (SELECT kind, hash FROM clips WHERE id = ? AND deleted_at IS NOT NULL)
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
        try pruneImageFiles()
    }

    func emptyTrash() throws {
        try run("DELETE FROM clips WHERE deleted_at IS NOT NULL")
        try pruneImageFiles()
    }

    func purgeExpiredTrash() throws {
        try run("DELETE FROM clips WHERE deleted_at < ?", .real(now() - Self.trashRetention))
        try pruneImageFiles()
    }

    /// Drops image files no longer referenced by any row. Runs only after a deletion or at launch.
    private func pruneImageFiles() throws {
        var digests: Set<Data> = []
        try run("SELECT image FROM clips WHERE image IS NOT NULL", [], row: { statement in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  let bytes = sqlite3_column_blob(statement, 0)
            else { return }
            digests.insert(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        })
        try images.removeOrphanedFiles(referencedBy: digests)
    }

    /// Whole days, rounded up, until a clip trashed at `deletedAt` is purged.
    static func trashDaysLeft(deletedAt: Date, now: Date = Date()) -> Int {
        let seconds = deletedAt.addingTimeInterval(trashRetention).timeIntervalSince(now)
        return max(1, Int((seconds / (24 * 60 * 60)).rounded(.up)))
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
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Character position of the first match, for the excerpt around it. lower() folds only
        // ASCII, so a match that differs in non-ASCII case gets no excerpt.
        let position = term.isEmpty ? "NULL" : "instr(lower(text), lower(?))"
        var clips: [Clip] = []
        clips.reserveCapacity(limit)
        // The page is picked first with only ids and match positions, so SQLite never holds
        // the texts of a whole page at once.
        // The preview is the trimmed text with whitespace runs collapsed, so any difference after
        // trimming means line breaks or truncation.
        try run(
            """
            SELECT c.id, c.preview, c.link, c.kind = 0 AND trim(c.text, char(32, 9, 10, 13)) <> c.preview,
                c.image, c.image_width, c.image_height, c.deleted_at, p.position,
                CASE WHEN p.position > 0 THEN substr(c.text, max(1, p.position - \(Self.matchLead)), \(Self.excerptLength)) END
            FROM (
                SELECT id, \(order) AS sort, \(position) AS position FROM clips
                WHERE \(filter) ORDER BY \(order) DESC LIMIT ? OFFSET ?
            ) AS p
            JOIN clips AS c ON c.id = p.id
            ORDER BY p.sort DESC
            """,
            (term.isEmpty ? [] : [.text(term)]) + values + [.int(Int64(limit)), .int(Int64(offset))]
        ) { statement in
            let excerpt = Self.string(statement, 9).map { raw in
                let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return sqlite3_column_int64(statement, 8) > Int64(Self.matchLead + 1) ? "…" + line : line
            }
            clips.append(Clip(
                id: sqlite3_column_int64(statement, 0),
                preview: Self.string(statement, 1) ?? "",
                link: Self.string(statement, 2).flatMap(URL.init(string:)),
                isAbridged: sqlite3_column_int(statement, 3) != 0,
                image: Self.blob(statement, 4),
                imageSize: Self.imageSize(statement, 5, 6),
                deletedAt: Self.date(statement, 7),
                matchExcerpt: excerpt
            ))
        }
        return clips
    }

    /// The content written back to the pasteboard when `id` is activated.
    func content(of id: Int64) throws -> ClipContent? {
        var content: ClipContent?
        try run("SELECT text, image, image_width, image_height FROM clips WHERE id = ?", [.int(id)]) { statement in
            if let digest = Self.blob(statement, 1), let data = self.images.data(digest: digest) {
                content = .image(data, Self.imageSize(statement, 2, 3) ?? .zero)
            } else {
                content = .text(Self.string(statement, 0) ?? "")
            }
        }
        return content
    }

    /// A downscaled image for a list row. The 32-byte hash, not the PNG data, keys the cache.
    func thumbnail(digest: Data, size: CGSize) -> NSImage? {
        imagesCache.image(digest: digest, size: size, using: images)
    }

    /// Drops decoded row thumbnails when the panel closes. Disk files stay cached.
    func clearThumbnails() { imagesCache.clear() }

    /// Returns at most `limit` characters of the clip's text, its total length in characters,
    /// and when it was last copied.
    func excerpt(of id: Int64, limit: Int) throws -> (text: String, length: Int, usedAt: Date)? {
        var excerpt: (String, Int, Date)?
        try run("SELECT substr(text, 1, ?), length(text), used_at FROM clips WHERE id = ?", [.int(Int64(limit)), .int(id)]) {
            excerpt = (Self.string($0, 0) ?? "", Int(sqlite3_column_int64($0, 1)), Date(timeIntervalSince1970: sqlite3_column_double($0, 2)))
        }
        return excerpt
    }

    /// Image clip preview: file-backed image, pixel size, byte count, and copy time.
    func imagePreview(of id: Int64) throws -> (image: NSImage, size: CGSize, byteCount: Int, usedAt: Date)? {
        var result: (NSImage, CGSize, Int, Date)?
        try run("SELECT image, image_width, image_height, used_at FROM clips WHERE id = ?", [.int(id)]) { statement in
            guard let digest = Self.blob(statement, 0),
                  let loaded = self.images.preview(digest: digest) else { return }
            result = (loaded.image, Self.imageSize(statement, 1, 2) ?? .zero, loaded.byteCount,
                      Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)))
        }
        return result
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

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column)
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func imageSize(_ statement: OpaquePointer, _ width: Int32, _ height: Int32) -> CGSize? {
        guard sqlite3_column_type(statement, width) != SQLITE_NULL,
              sqlite3_column_type(statement, height) != SQLITE_NULL
        else { return nil }
        return CGSize(width: Double(sqlite3_column_int64(statement, width)),
                      height: Double(sqlite3_column_int64(statement, height)))
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }
}
