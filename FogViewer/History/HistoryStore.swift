import Foundation

/// 霧の履歴（差分）を保存する SQLite。
/// 書き込むのは見張り役（`--watch`）だけで、アプリ本体は読み取り専用で開く。
final class HistoryStore {
    static let schemaVersion = "1"

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FogViewer", isDirectory: true)
    }

    static var defaultURL: URL { defaultDirectory.appendingPathComponent("history.sqlite") }

    let url: URL
    let db: SQLiteDatabase

    init(url: URL = HistoryStore.defaultURL, readOnly: Bool = false) throws {
        self.url = url
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        db = try SQLiteDatabase(url: url, readOnly: readOnly)
        if !readOnly { try migrate() }
    }

    private func migrate() throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS events (
          id               INTEGER PRIMARY KEY,
          kind             TEXT NOT NULL,
          detected_at      REAL NOT NULL,
          prev_checked_at  REAL,
          file_mtime_min   REAL,
          file_mtime_max   REAL,
          bits_added       INTEGER NOT NULL,
          bits_removed     INTEGER NOT NULL,
          backup_name      TEXT,
          source           TEXT  -- 出どころ（'icloud' / 'timeline' / 'line' など）。backfill の置き換えに使う
        );
        CREATE TABLE IF NOT EXISTS block_diffs (
          event_id   INTEGER NOT NULL REFERENCES events(id),
          block_key  INTEGER NOT NULL,
          added      BLOB,
          removed    BLOB,
          PRIMARY KEY (event_id, block_key)
        );
        CREATE INDEX IF NOT EXISTS block_diffs_by_block ON block_diffs(block_key);
        CREATE TABLE IF NOT EXISTS current_blocks (block_key INTEGER PRIMARY KEY, bitmap BLOB NOT NULL);  -- DiffCodec 形式
        CREATE TABLE IF NOT EXISTS tile_files (name TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS heartbeat (day TEXT PRIMARY KEY, last_checked_at REAL NOT NULL, checks INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE INDEX IF NOT EXISTS events_by_time ON events(detected_at);
        """)
        try setMeta("schema_version", Self.schemaVersion)
    }

    // MARK: - 読み取り

    /// 今の霧（前回確認した時点）のブロックすべて。
    func allCurrentBlocks() throws -> [UInt32: [UInt8]] {
        let stmt = try db.prepare("SELECT block_key, bitmap FROM current_blocks")
        var out: [UInt32: [UInt8]] = [:]
        while try stmt.step() {
            if let bitmap = stmt.blob(1).flatMap(DiffCodec.decode) { out[UInt32(stmt.int(0))] = bitmap }
        }
        return out
    }

    func baselineBlocks() throws -> [UInt32: [UInt8]] {
        let stmt = try db.prepare("""
        SELECT d.block_key, d.added FROM block_diffs d JOIN events e ON e.id = d.event_id
        WHERE e.kind = 'baseline'
        """)
        var out: [UInt32: [UInt8]] = [:]
        while try stmt.step() {
            if let bitmap = stmt.blob(1).flatMap(DiffCodec.decode) { out[UInt32(stmt.int(0))] = bitmap }
        }
        return out
    }

    func tileFiles() throws -> [String: TileFileInfo] {
        let stmt = try db.prepare("SELECT name, size, mtime FROM tile_files")
        var out: [String: TileFileInfo] = [:]
        while try stmt.step() {
            out[stmt.text(0) ?? ""] = TileFileInfo(size: stmt.int(1), mtime: stmt.real(2) ?? 0)
        }
        return out
    }

    func hasBaseline() throws -> Bool {
        let stmt = try db.prepare("SELECT 1 FROM events WHERE kind = 'baseline' LIMIT 1")
        return try stmt.step()
    }

    /// タイル (tx, ty) に含まれる、前回時点のブロック。
    func currentBlocks(tileX tx: Int, tileY ty: Int) throws -> [UInt32: [UInt8]] {
        let w = FowFormat.tileWidth
        let bx0 = tx * w, by0 = ty * w
        let stmt = try db.prepare("""
        SELECT block_key, bitmap FROM current_blocks
        WHERE block_key BETWEEN ? AND ? AND (block_key & 65535) BETWEEN ? AND ?
        """)
        let keyMin: Int64 = Int64(bx0) << 16
        let keyMax: Int64 = (Int64(bx0 + w - 1) << 16) | 0xFFFF
        try stmt.bind([.int(keyMin), .int(keyMax), .int(Int64(by0)), .int(Int64(by0 + w - 1))])
        var out: [UInt32: [UInt8]] = [:]
        while try stmt.step() {
            if let bitmap = stmt.blob(1).flatMap(DiffCodec.decode) {
                out[UInt32(stmt.int(0))] = bitmap
            }
        }
        return out
    }

    func meta(_ key: String) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM meta WHERE key = ?")
        try stmt.bind([.text(key)])
        return try stmt.step() ? stmt.text(0) : nil
    }

    func summary() throws -> HistorySummary {
        let stmt = try db.prepare("""
        SELECT COUNT(*), MAX(detected_at), SUM(bits_added) FROM events WHERE kind = 'update'
        """)
        _ = try stmt.step()
        let updates = Int(stmt.int(0))
        let lastEvent = stmt.real(1)
        let addedSince = Int(stmt.int(2))
        let base = try db.prepare("SELECT detected_at FROM events WHERE kind = 'baseline' LIMIT 1")
        let baselineAt = try base.step() ? base.real(0) : nil
        let lastChecked = try meta("last_checked_at").flatMap(Double.init)
        let back = try db.prepare("SELECT COUNT(*), MIN(detected_at), SUM(bits_added) FROM events WHERE kind = 'backfill'")
        _ = try back.step()
        let backfillDays = Int(back.int(0))
        let backfillEarliest = back.real(1)
        let backfillBits = Int(back.int(2))
        return HistorySummary(baselineAt: baselineAt.map(Date.init(timeIntervalSince1970:)),
                              updateCount: updates,
                              lastEventAt: lastEvent.map(Date.init(timeIntervalSince1970:)),
                              bitsAddedSinceBaseline: addedSince,
                              lastCheckedAt: lastChecked.map(Date.init(timeIntervalSince1970:)),
                              backfillDays: backfillDays,
                              backfillEarliest: backfillEarliest.map(Date.init(timeIntervalSince1970:)),
                              backfillBits: backfillBits)
    }

    // MARK: - 書き込み

    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
    }

    func deleteMeta(_ key: String) throws {
        try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
    }

    /// - Parameter updateLastChecked: false なら「最後に確認した時刻」は進めない
    ///   （見送った確認の後でも、次の記録の prev_checked_at が変化の始まりを指すように）。
    func recordHeartbeat(at date: Date, updateLastChecked: Bool = true) throws {
        let day = Self.dayFormatter.string(from: date)
        try db.run("""
        INSERT INTO heartbeat(day, last_checked_at, checks) VALUES (?, ?, 1)
        ON CONFLICT(day) DO UPDATE SET last_checked_at = excluded.last_checked_at, checks = checks + 1
        """, [.text(day), .real(date.timeIntervalSince1970)])
        if updateLastChecked { try setMeta("last_checked_at", String(date.timeIntervalSince1970)) }
    }

    /// iCloud の記録 1 件と、そのブロックごとの差分を書く（トランザクションは呼び出し側）。
    func insertEvent(_ change: SyncChange, backupName: String? = nil) throws -> Int64 {
        try db.run("""
        INSERT INTO events(kind, detected_at, prev_checked_at, file_mtime_min, file_mtime_max,
                           bits_added, bits_removed, backup_name, source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'icloud')
        """, [.text(change.kind.rawValue), .real(change.detectedAt.timeIntervalSince1970),
              .optional(change.prevCheckedAt?.timeIntervalSince1970),
              .optional(change.fileMtimeMin), .optional(change.fileMtimeMax),
              .int(Int64(change.bitsAdded)), .int(Int64(change.bitsRemoved)),
              backupName.map { .text($0) } ?? .null])
        let id = db.lastInsertRowID
        let insert = try db.prepare("INSERT INTO block_diffs(event_id, block_key, added, removed) VALUES (?, ?, ?, ?)")
        for diff in change.diffs {
            try insert.bind([.int(id), .int(Int64(diff.blockKey)), .optional(diff.added), .optional(diff.removed)])
            try insert.stepDone()
        }
        return id
    }

    /// 1 回分の変化をまとめて書く。差分が空なら events には残さず、ファイル情報だけ更新する。
    /// - Returns: 記録したイベントの ID（差分なしなら nil）
    @discardableResult
    func apply(_ change: SyncChange, backupName: String?) throws -> Int64? {
        try db.transaction {
            let eventID = change.diffs.isEmpty ? nil : try insertEvent(change, backupName: backupName)
            let upsert = try db.prepare("""
            INSERT INTO current_blocks(block_key, bitmap) VALUES (?, ?)
            ON CONFLICT(block_key) DO UPDATE SET bitmap = excluded.bitmap
            """)
            let delete = try db.prepare("DELETE FROM current_blocks WHERE block_key = ?")
            for (key, bitmap) in change.newBlockStates {
                // 差分と同じ書き方で保存する（512 バイトのままだと 1 ブロック平均 18 ビットに対して大きすぎる）。
                if let bitmap, let encoded = DiffCodec.encode(bitmap) {
                    try upsert.bind([.int(Int64(key)), .blob(encoded)])
                    try upsert.stepDone()
                } else {
                    try delete.bind([.int(Int64(key))])
                    try delete.stepDone()
                }
            }
            let fileUpsert = try db.prepare("""
            INSERT INTO tile_files(name, size, mtime) VALUES (?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET size = excluded.size, mtime = excluded.mtime
            """)
            for (name, info) in change.updatedFiles {
                try fileUpsert.bind([.text(name), .int(info.size), .real(info.mtime)])
                try fileUpsert.stepDone()
            }
            let fileDelete = try db.prepare("DELETE FROM tile_files WHERE name = ?")
            for name in change.removedFiles {
                try fileDelete.bind([.text(name)])
                try fileDelete.stepDone()
            }
            return eventID
        }
    }

    struct BackfillEvent {
        var at: Date
        var bitsAdded: Int
        var diffs: [SyncChange.BlockDiff]
        /// 出どころ（timeline / line など）。nil なら replaceBackfill の source。
        var source: String? = nil
    }

    /// 出どころが `sources` の backfill イベントを消して、`events` で作り直す。ほかの出どころの backfill は残す。
    /// `events` の出どころが nil なら、`sources` のうち先頭（並べ替えた最初）を使う。
    func replaceBackfill(sources: Set<String>, events: [BackfillEvent]) throws {
        precondition(!sources.isEmpty)
        let list = sources.sorted()
        let placeholders = list.map { _ in "?" }.joined(separator: ", ")
        let source = list[0]
        try db.transaction {
            try db.run("""
            DELETE FROM block_diffs WHERE event_id IN
              (SELECT id FROM events WHERE kind = 'backfill' AND source IN (\(placeholders)))
            """, list.map { .text($0) })
            try db.run("DELETE FROM events WHERE kind = 'backfill' AND source IN (\(placeholders))", list.map { .text($0) })
            let insertEvent = try db.prepare("""
            INSERT INTO events(kind, detected_at, bits_added, bits_removed, source) VALUES ('backfill', ?, ?, 0, ?)
            """)
            let insertDiff = try db.prepare("INSERT INTO block_diffs(event_id, block_key, added, removed) VALUES (?, ?, ?, NULL)")
            for event in events {
                try insertEvent.bind([.real(event.at.timeIntervalSince1970), .int(Int64(event.bitsAdded)), .text(event.source ?? source)])
                try insertEvent.stepDone()
                let id = db.lastInsertRowID
                for diff in event.diffs {
                    try insertDiff.bind([.int(id), .int(Int64(diff.blockKey)), .optional(diff.added)])
                    try insertDiff.stepDone()
                }
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

struct TileFileInfo: Equatable {
    var size: Int64
    var mtime: Double
}

struct HistorySummary {
    var baselineAt: Date?
    var updateCount: Int
    var lastEventAt: Date?
    var bitsAddedSinceBaseline: Int
    var lastCheckedAt: Date?
    var backfillDays = 0
    var backfillEarliest: Date?
    var backfillBits = 0
}

/// 1 回の確認で見つかった変化。
struct SyncChange {
    enum Kind: String { case baseline, update }

    struct BlockDiff {
        var blockKey: UInt32
        var added: Data?
        var removed: Data?
    }

    var kind: Kind
    var detectedAt: Date
    var prevCheckedAt: Date?
    var fileMtimeMin: Double?
    var fileMtimeMax: Double?
    var diffs: [BlockDiff] = []
    var bitsAdded = 0
    var bitsRemoved = 0
    /// 新しい状態。nil はブロックが消えたことを表す。
    var newBlockStates: [UInt32: [UInt8]?] = [:]
    var updatedFiles: [String: TileFileInfo] = [:]
    var removedFiles: [String] = []
}
