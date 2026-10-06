import Foundation

/// 履歴の手直し。誤記録を後から取り除くときに使う。
extension HistoryStore {
    struct PurgeResult: Equatable {
        var collapsedEvents: Int
        var purgedBits: Int
        var netAddedBits: Int
        var deletedEmptyEvents: Int
    }

    /// 連続する iCloud の記録（baseline / update）`eventIDs` を 1 つの正味の変化にまとめ、
    /// 正味で消えたビットを「誤記録」として履歴のすべての記録から取り除く。
    ///
    /// 例：Fog of World で誤った航路を消して同期したら、同期の途中で一度全部消えて入れ直された。
    /// → その 2 件をまとめると「航路が消えた」だけになり、航路を最初からなかったことにする。
    /// 正味で増えたビットがあれば、最後の記録の時刻に 1 件の update として残す。
    func collapseAndPurge(eventIDs: [Int64]) throws -> PurgeResult {
        let ids = Set(eventIDs)
        let sequence = try icloudEventIDs()
        guard let first = sequence.firstIndex(where: ids.contains),
              let last = sequence.lastIndex(where: ids.contains),
              Set(sequence[first...last]) == ids else {
            throw SQLiteDatabase.Error(message: "まとめる記録は、iCloud の記録の中で連続している必要があります: \(eventIDs.sorted())")
        }

        // 前後の状態を差分の積み重ねから組み立て直す。
        let before = try replay(sequence[..<first])
        let after = try replay(sequence[first...last], from: before)
        var netRemoved: [UInt32: [UInt8]] = [:]
        var netAdded: [UInt32: [UInt8]] = [:]
        for key in Set(before.keys).union(after.keys) {
            let b = before[key], a = after[key]
            if let b { let r = DiffCodec.subtract(b, a); if DiffCodec.bitCount(r) > 0 { netRemoved[key] = r } }
            if let a { let n = DiffCodec.subtract(a, b); if DiffCodec.bitCount(n) > 0 { netAdded[key] = n } }
        }
        let lastAt = try detectedAt(sequence[last])

        return try db.transaction {
            for id in ids { try deleteEvent(id) }
            var result = PurgeResult(collapsedEvents: ids.count,
                                     purgedBits: netRemoved.values.reduce(0) { $0 + DiffCodec.bitCount($1) },
                                     netAddedBits: netAdded.values.reduce(0) { $0 + DiffCodec.bitCount($1) },
                                     deletedEmptyEvents: 0)
            result.deletedEmptyEvents = try purge(netRemoved)
            if !netAdded.isEmpty {
                var change = SyncChange(kind: .update, detectedAt: lastAt)
                HistoryRecorder.diff(old: [:], new: netAdded, into: &change)
                change.newBlockStates = [:]  // current_blocks は既に最新
                _ = try insertEvent(change)
            }
            return result
        }
    }

    /// iCloud の記録（baseline / update）の ID を古い順に。
    func icloudEventIDs() throws -> [Int64] {
        let stmt = try db.prepare("SELECT id FROM events WHERE kind IN ('baseline', 'update') ORDER BY id")
        var out: [Int64] = []
        while try stmt.step() { out.append(stmt.int(0)) }
        return out
    }

    /// 記録 1 件のブロックごとの差分。
    func eventDiffs(_ id: Int64) throws -> [UInt32: (added: [UInt8]?, removed: [UInt8]?)] {
        let stmt = try db.prepare("SELECT block_key, added, removed FROM block_diffs WHERE event_id = ?")
        try stmt.bind([.int(id)])
        var out: [UInt32: (added: [UInt8]?, removed: [UInt8]?)] = [:]
        while try stmt.step() {
            out[UInt32(stmt.int(0))] = (stmt.blob(1).flatMap(DiffCodec.decode), stmt.blob(2).flatMap(DiffCodec.decode))
        }
        return out
    }

    /// 記録を順に重ねた状態。
    func replay<S: Sequence>(_ ids: S, from start: [UInt32: [UInt8]] = [:]) throws -> [UInt32: [UInt8]] where S.Element == Int64 {
        var state = start
        for id in ids {
            for (key, diff) in try eventDiffs(id) {
                var bitmap = state[key] ?? [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)
                if let r = diff.removed { bitmap = zip(bitmap, r).map { $0 & ~$1 } }
                if let a = diff.added { bitmap = zip(bitmap, a).map { $0 | $1 } }
                state[key] = DiffCodec.bitCount(bitmap) > 0 ? bitmap : nil
            }
        }
        return state
    }

    /// `mask` のビットを、すべての記録の追加・削除から取り除く。空になった記録（baseline 以外）は消す。
    /// - Returns: 空になって消した記録の数
    private func purge(_ mask: [UInt32: [UInt8]]) throws -> Int {
        guard !mask.isEmpty else { return 0 }
        let select = try db.prepare("SELECT event_id, added, removed FROM block_diffs WHERE block_key = ?")
        let update = try db.prepare("UPDATE block_diffs SET added = ?, removed = ? WHERE event_id = ? AND block_key = ?")
        let delete = try db.prepare("DELETE FROM block_diffs WHERE event_id = ? AND block_key = ?")
        var touched = Set<Int64>()
        for (key, m) in mask {
            try select.bind([.int(Int64(key))])
            var rows: [(Int64, [UInt8]?, [UInt8]?)] = []
            while try select.step() {
                rows.append((select.int(0), select.blob(1).flatMap(DiffCodec.decode), select.blob(2).flatMap(DiffCodec.decode)))
            }
            for (eventID, added, removed) in rows {
                let a = added.map { DiffCodec.subtract($0, m) }.flatMap(DiffCodec.encode)
                let r = removed.map { DiffCodec.subtract($0, m) }.flatMap(DiffCodec.encode)
                if a == nil && r == nil {
                    try delete.bind([.int(eventID), .int(Int64(key))])
                    try delete.stepDone()
                } else {
                    try update.bind([.optional(a), .optional(r), .int(eventID), .int(Int64(key))])
                    try update.stepDone()
                }
                touched.insert(eventID)
            }
        }
        var deleted = 0
        for id in touched {
            let (added, removed, rows) = try counts(id)
            let kind = try self.kind(id)
            if rows == 0 && kind != "baseline" {
                try deleteEvent(id)
                deleted += 1
            } else {
                try db.run("UPDATE events SET bits_added = ?, bits_removed = ? WHERE id = ?",
                           [.int(Int64(added)), .int(Int64(removed)), .int(id)])
            }
        }
        return deleted
    }

    private func counts(_ id: Int64) throws -> (added: Int, removed: Int, rows: Int) {
        var added = 0, removed = 0, rows = 0
        for (_, d) in try eventDiffs(id) {
            added += d.added.map(DiffCodec.bitCount) ?? 0
            removed += d.removed.map(DiffCodec.bitCount) ?? 0
            rows += 1
        }
        return (added, removed, rows)
    }

    private func kind(_ id: Int64) throws -> String? {
        let stmt = try db.prepare("SELECT kind FROM events WHERE id = ?")
        try stmt.bind([.int(id)])
        return try stmt.step() ? stmt.text(0) : nil
    }

    private func detectedAt(_ id: Int64) throws -> Date {
        let stmt = try db.prepare("SELECT detected_at FROM events WHERE id = ?")
        try stmt.bind([.int(id)])
        guard try stmt.step(), let t = stmt.real(0) else { throw SQLiteDatabase.Error(message: "記録 \(id) がありません") }
        return Date(timeIntervalSince1970: t)
    }

    private func deleteEvent(_ id: Int64) throws {
        try db.run("DELETE FROM block_diffs WHERE event_id = ?", [.int(id)])
        try db.run("DELETE FROM events WHERE id = ?", [.int(id)])
    }
}
