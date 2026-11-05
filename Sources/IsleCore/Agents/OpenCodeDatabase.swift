import Foundation
import SQLite3

/// OpenCode 2 keeps its messages in one SQLite database (`~/.local/share/opencode/opencode.db`) instead of one JSON file per
/// message. Only the fields Isle counts are selected (role, model, token counts, timestamps, project folder); message text,
/// accounts and credentials in the same file are never queried.
public enum OpenCodeDatabase {
    public struct Row: Equatable {
        public var messageID: String
        public var sessionID: String
        /// Milliseconds since 1970 of the last write to the row. Rows are rewritten while a reply streams.
        public var updatedMillis: Int64
        /// JSON with only the counted fields, shaped like one OpenCode message file.
        public var json: Data
        public var directory: String?
    }

    /// Messages written at or after `since` (milliseconds), oldest first, or nil if the database can't be read.
    public static func messages(at url: URL, updatedSince since: Int64, limit: Int = 20_000) -> [Row]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        let sql = """
        SELECT m.id, m.session_id, m.time_updated,
               json_object('role', json_extract(m.data, '$.role'),
                           'modelID', json_extract(m.data, '$.modelID'),
                           'model', json(json_extract(m.data, '$.model')),
                           'tokens', json(json_extract(m.data, '$.tokens')),
                           'time', json(json_extract(m.data, '$.time')),
                           'path', json(json_extract(m.data, '$.path'))),
               s.directory
        FROM message m LEFT JOIN session s ON s.id = m.session_id
        WHERE m.time_updated >= ? ORDER BY m.time_updated, m.id LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(0), let session = text(1), let json = text(3) else { continue }
            rows.append(Row(messageID: id, sessionID: session, updatedMillis: sqlite3_column_int64(stmt, 2), json: Data(json.utf8), directory: text(4)))
        }
        return rows
    }
}
