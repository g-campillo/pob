import Foundation
import SQLite3

nonisolated struct HistoryEntry: Equatable, Sendable {
    let url: URL
    let title: String
    let visitCount: Int
    let lastVisit: Date
}

/// Searchable page history in SQLite. Any failure is logged and leaves the store empty or unchanged, so history never gets in the way of navigation.
actor HistoryStore {
    // Only the actor touches it; unsafe solely so deinit can close it.
    nonisolated(unsafe) private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(file: URL) {
        db = Self.open(file)
    }

    private static func open(_ file: URL) -> OpaquePointer? {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("History: creating folder failed: \(error)")
        }
        var handle: OpaquePointer?
        // Idempotent, so reopening an existing file keeps its entries.
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, sqlite3_exec(handle, """
            CREATE TABLE IF NOT EXISTS visits(url TEXT PRIMARY KEY, title TEXT NOT NULL, visit_count INTEGER NOT NULL, last_visit REAL NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(url, title);
            PRAGMA user_version = 1;
            """, nil, nil, nil) == SQLITE_OK else {
            NSLog("History: opening \(file.path) failed")
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    deinit { sqlite3_close(db) }

    func record(url: URL, title: String, at date: Date = .now) {
        transaction {
            // A repeat visit with no title yet keeps the one it has.
            guard step("""
                INSERT INTO visits(url, title, visit_count, last_visit) VALUES(?1, ?2, 1, ?3)
                ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, last_visit = ?3,
                    title = CASE WHEN ?2 = '' THEN title ELSE ?2 END
                """, [.text(url.absoluteString), .text(title), .real(date.timeIntervalSince1970)]) else { return false }
            return reindex(url)
        }
    }

    /// The title usually arrives after the load finishes. Does nothing for a page with no entry.
    func updateTitle(url: URL, title: String) {
        guard let db else { return }
        transaction {
            guard step("UPDATE visits SET title = ?2 WHERE url = ?1", [.text(url.absoluteString), .text(title)]),
                  sqlite3_changes(db) > 0 else { return true }
            return reindex(url)
        }
    }

    func search(_ query: String, limit: Int) -> [HistoryEntry] {
        let match = query.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")
        guard let db, !match.isEmpty else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT v.url, v.title, v.visit_count, v.last_visit FROM history_fts
            JOIN visits v ON v.rowid = history_fts.rowid WHERE history_fts MATCH ?1
            ORDER BY v.visit_count * 1.0 / (1 + (?2 - v.last_visit) / 86400.0) DESC LIMIT ?3
            """, -1, &statement, nil) == SQLITE_OK else {
            fail("search")
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, Self.transient)
        sqlite3_bind_double(statement, 2, Date.now.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, Int64(limit))
        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = URL(string: String(cString: sqlite3_column_text(statement, 0))) else { continue }
            entries.append(HistoryEntry(
                url: url,
                title: String(cString: sqlite3_column_text(statement, 1)),
                visitCount: Int(sqlite3_column_int64(statement, 2)),
                lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return entries
    }

    func prune(before date: Date) {
        let cutoff = date.timeIntervalSince1970
        transaction {
            step("DELETE FROM history_fts WHERE rowid IN (SELECT rowid FROM visits WHERE last_visit < ?1)", [.real(cutoff)])
                && step("DELETE FROM visits WHERE last_visit < ?1", [.real(cutoff)])
        }
    }

    /// Leaves nothing readable in the file. A delete alone keeps the rows in free pages and the terms in old index
    /// segments, so the index is rebuilt, empty, and the file rewritten without the free pages.
    func clear() {
        transaction {
            run("DELETE FROM history_fts") && run("DELETE FROM visits")
                && run("INSERT INTO history_fts(history_fts) VALUES('rebuild')")
        }
        run("VACUUM")
    }

    // MARK: SQLite

    private enum Value {
        case text(String), real(Double)
    }

    /// Rewrites the page's search row from its visit row.
    private func reindex(_ url: URL) -> Bool {
        let key = [Value.text(url.absoluteString)]
        return step("DELETE FROM history_fts WHERE rowid = (SELECT rowid FROM visits WHERE url = ?1)", key)
            && step("INSERT INTO history_fts(rowid, url, title) SELECT rowid, url, title FROM visits WHERE url = ?1", key)
    }

    private func transaction(_ body: () -> Bool) {
        guard db != nil, run("BEGIN") else { return }
        if body() {
            if !run("COMMIT") { run("ROLLBACK") }
        } else {
            run("ROLLBACK")
        }
    }

    @discardableResult
    private func run(_ sql: String) -> Bool {
        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK { return true }
        return fail(sql)
    }

    @discardableResult
    private func step(_ sql: String, _ values: [Value]) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return fail(sql) }
        for (index, value) in values.enumerated() {
            switch value {
            case .text(let text): sqlite3_bind_text(statement, Int32(index + 1), text, -1, Self.transient)
            case .real(let number): sqlite3_bind_double(statement, Int32(index + 1), number)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { return fail(sql) }
        return true
    }

    @discardableResult
    private func fail(_ what: String) -> Bool {
        NSLog("History: \(what) failed: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")")
        return false
    }
}
