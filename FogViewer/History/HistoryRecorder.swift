import Foundation

/// Sync フォルダを確認し、前回からの変化を HistoryStore に記録する。
/// 見張り役（`FogViewer --watch`）から 1 回ずつ呼ばれる。
struct HistoryRecorder {
    struct Options {
        /// 変化を見つけてから、これだけ変化が止まっていたら記録する（同期途中を読まないため）。
        var settleInterval: TimeInterval = 120
        /// 変化が止まったかを確かめる間隔。
        var pollInterval: TimeInterval = 30
        /// 変化が止まらなくても、これだけ待ったら記録する。
        var maxWait: TimeInterval = 15 * 60
        /// フォルダが空になったり、ファイルが一度に大量に消えたら、同期の途中とみなして記録を見送る。
        /// ただしこの時間を超えて続いたら、本当に消えたとみなして記録する。
        var drasticRemovalGrace: TimeInterval = 6 * 60 * 60
        /// 記録したときに Sync フォルダの zip 控えを残す場所（nil なら残さない）。
        var backupDirectory: URL? = HistoryStore.defaultDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    enum Outcome: Equatable {
        case unchanged
        case filesChangedWithoutBitDiff
        /// ファイルが大量に消えていたので、同期の途中とみなして見送った。
        case deferredDrasticRemoval(removedFiles: Int, previousFiles: Int)
        case recorded(eventID: Int64, added: Int, removed: Int)
    }

    let syncFolder: URL
    let store: HistoryStore
    var options = Options()
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var log: (String) -> Void = { _ in }

    func checkOnce() throws -> Outcome {
        let startedAt = now()
        let prevChecked = try store.meta("last_checked_at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let previous = try store.tileFiles()
        let hasBaseline = try store.hasBaseline()

        var listing = Self.listFiles(in: syncFolder)
        if hasBaseline && listing == previous {
            try store.recordHeartbeat(at: startedAt)
            return .unchanged
        }

        // 同期の途中を読まないよう、一覧が settleInterval のあいだ変わらなくなるまで待つ。
        if hasBaseline && options.settleInterval > 0 {
            log("変化を検出。落ち着くのを待ちます")
            var lastChange = now()
            while now().timeIntervalSince(lastChange) < options.settleInterval,
                  now().timeIntervalSince(startedAt) < options.maxWait {
                sleep(options.pollInterval)
                let again = Self.listFiles(in: syncFolder)
                if again != listing {
                    listing = again
                    lastChange = now()
                }
            }
        }

        var change = SyncChange(kind: hasBaseline ? .update : .baseline,
                                detectedAt: startedAt, prevCheckedAt: prevChecked)
        let changedNames = listing.filter { previous[$0.key] != $0.value }.map(\.key).sorted()
        let removedNames = previous.keys.filter { listing[$0] == nil }.sorted()

        // Fog of World は同期の途中で Sync フォルダを一度空にして入れ直すことがある。
        // そのまま記録すると「全部消えて、また全部増えた」履歴になるので、入れ直しが終わるまで見送る。
        // フォルダが空になったときは常に、そうでなければ 10 個以上かつ半分以上消えたときに見送る
        // （ファイルが数個しかないときに 1 個消えただけで見送らないように）。
        let drastic = !previous.isEmpty && (listing.isEmpty || (removedNames.count >= 10 && removedNames.count * 2 > previous.count))
        if hasBaseline && drastic {
            let stored = try store.meta("drastic_removal_since").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            if startedAt.timeIntervalSince(stored ?? startedAt) >= options.drasticRemovalGrace {
                log("ファイルの大量削除が続いているので、本当に消えたとみなして記録します")
            } else {
                if stored == nil { try store.setMeta("drastic_removal_since", String(startedAt.timeIntervalSince1970)) }
                log("ファイルが \(previous.count) 個中 \(removedNames.count) 個消えています。同期の途中とみなして見送ります")
                try store.recordHeartbeat(at: now(), updateLastChecked: false)
                return .deferredDrasticRemoval(removedFiles: removedNames.count, previousFiles: previous.count)
            }
        }
        try store.deleteMeta("drastic_removal_since")

        var mtimes: [Double] = []
        for name in changedNames {
            guard let tileID = FowFormat.tileID(fromFilename: name) else { continue }
            guard let data = Self.read(syncFolder.appendingPathComponent(name)) else {
                // 読めなかったファイルは次回に回す（tile_files を更新しない）。
                log("読めなかった: \(name)")
                continue
            }
            var newBlocks: [UInt32: FogBlock] = [:]
            do {
                try FogParser.parseTile(filename: name, data: data, into: &newBlocks)
            } catch {
                log("解析できなかった: \(name)")
                continue
            }
            let tx = tileID % FowFormat.mapWidth, ty = tileID / FowFormat.mapWidth
            let oldBlocks = try store.currentBlocks(tileX: tx, tileY: ty)
            Self.diff(old: oldBlocks, new: newBlocks.mapValues(\.bitmap), into: &change)
            change.updatedFiles[name] = listing[name]
            mtimes.append(listing[name]!.mtime)
        }
        for name in removedNames {
            guard let tileID = FowFormat.tileID(fromFilename: name) else { continue }
            let tx = tileID % FowFormat.mapWidth, ty = tileID / FowFormat.mapWidth
            Self.diff(old: try store.currentBlocks(tileX: tx, tileY: ty), new: [:], into: &change)
            change.removedFiles.append(name)
        }
        change.fileMtimeMin = mtimes.min()
        change.fileMtimeMax = mtimes.max()

        let backupName = change.diffs.isEmpty ? nil : try? makeBackup(at: startedAt)
        let eventID = try store.apply(change, backupName: backupName)
        try store.recordHeartbeat(at: now())

        if let eventID {
            log("記録: event \(eventID) +\(change.bitsAdded) -\(change.bitsRemoved) ビット")
            return .recorded(eventID: eventID, added: change.bitsAdded, removed: change.bitsRemoved)
        }
        return .filesChangedWithoutBitDiff
    }

    /// ブロック単位で old → new の差分を作り、change に加える。
    static func diff(old: [UInt32: [UInt8]], new: [UInt32: [UInt8]], into change: inout SyncChange) {
        for key in Set(old.keys).union(new.keys).sorted() {
            let o = old[key], n = new[key]
            if o == n { continue }
            let added = n.map { DiffCodec.subtract($0, o) }
            let removed = o.map { DiffCodec.subtract($0, n) }
            let addedCount = added.map(DiffCodec.bitCount) ?? 0
            let removedCount = removed.map(DiffCodec.bitCount) ?? 0
            // 値が nil（ブロック消滅）でもキーを残したいので updateValue を使う。
            change.newBlockStates.updateValue(n.flatMap { DiffCodec.bitCount($0) > 0 ? $0 : nil }, forKey: key)
            guard addedCount + removedCount > 0 else { continue }
            change.diffs.append(.init(blockKey: key,
                                      added: added.flatMap(DiffCodec.encode),
                                      removed: removed.flatMap(DiffCodec.encode)))
            change.bitsAdded += addedCount
            change.bitsRemoved += removedCount
        }
    }

    static func listFiles(in folder: URL) -> [String: TileFileInfo] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var out: [String: TileFileInfo] = [:]
        for url in urls {
            let v = try? url.resourceValues(forKeys: Set(keys))
            out[url.lastPathComponent] = TileFileInfo(size: Int64(v?.fileSize ?? -1),
                                                      mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return out
    }

    /// iCloud 上でまだ落ちていないファイルも、協調読み込みでダウンロードさせて読む。
    static func read(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
        return (data?.isEmpty == false) ? data : nil
    }

    /// Sync フォルダを zip にして控えを残す。ファイル協調の .forUploading で zip を作ってもらう。
    private func makeBackup(at date: Date) throws -> String? {
        guard let dir = options.backupDirectory else { return nil }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Sync-\(f.string(from: date)).zip"
        var copyError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: syncFolder, options: .forUploading, error: &coordError) { zipURL in
            do { try FileManager.default.copyItem(at: zipURL, to: dir.appendingPathComponent(name)) }
            catch { copyError = error }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        return name
    }
}
