import XCTest
@testable import FogViewer

final class DiffCodecTests: XCTestCase {
    func testSparseRoundTrip() throws {
        var bitmap = [UInt8](repeating: 0, count: 512)
        bitmap[0] = 0b1000_0000          // (0, 0)
        bitmap[63 * 8 + 7] = 0b0000_0001 // (63, 63)
        bitmap[10 * 8 + 2] = 0b0010_0000 // (18, 10)
        let encoded = try XCTUnwrap(DiffCodec.encode(bitmap))
        XCTAssertEqual(encoded.first, DiffCodec.sparseTag)
        XCTAssertEqual(encoded.count, 1 + 3 * 2)
        XCTAssertEqual(DiffCodec.decode(encoded), bitmap)
    }

    func testDenseRoundTrip() throws {
        var bitmap = [UInt8](repeating: 0, count: 512)
        for i in 0..<40 { bitmap[i] = 0xFF } // 320 ビット > 255
        let encoded = try XCTUnwrap(DiffCodec.encode(bitmap))
        XCTAssertEqual(encoded.first, DiffCodec.bitmapTag)
        XCTAssertEqual(encoded.count, 513)
        XCTAssertEqual(DiffCodec.decode(encoded), bitmap)
    }

    func testEmptyIsNil() {
        XCTAssertNil(DiffCodec.encode([UInt8](repeating: 0, count: 512)))
    }

    func testSubtract() {
        let new: [UInt8] = [0b1100_0000] + [UInt8](repeating: 0, count: 511)
        let old: [UInt8] = [0b0100_0001] + [UInt8](repeating: 0, count: 511)
        XCTAssertEqual(DiffCodec.subtract(new, old)[0], 0b1000_0000)
        XCTAssertEqual(DiffCodec.subtract(old, new)[0], 0b0000_0001)
        XCTAssertEqual(DiffCodec.subtract(new, nil), new)
    }
}

final class HistoryRecorderTests: XCTestCase {
    private var tmp: URL!
    private var sync: URL!
    private var store: HistoryStore!
    private var recorder: HistoryRecorder!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("FogHistoryTests-\(UUID().uuidString)")
        sync = tmp.appendingPathComponent("Sync")
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        store = try HistoryStore(url: tmp.appendingPathComponent("history.sqlite"))
        recorder = HistoryRecorder(syncFolder: sync, store: store)
        recorder.options.settleInterval = 0
        recorder.options.backupDirectory = tmp.appendingPathComponent("backups")
        recorder.now = { [unowned self] in clock }
        recorder.sleep = { _ in }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// タイル ID ごとのファイル名。先頭 4 文字と末尾 2 文字は解読に使われないので適当でよい。
    private func filename(tileID: Int) -> String {
        let mask = Array("olhwjsktri")
        return "abcd" + String(String(tileID).map { mask[Int(String($0))!] }) + "xx"
    }

    /// ブロック (blockX, blockY) にビットを立てたタイルファイルを書く。
    private func writeTile(id: Int, blocks: [(x: Int, y: Int, bits: [(Int, Int)])], mtime: Date) throws {
        var raw = [UInt8](repeating: 0, count: FowFormat.tileHeaderSize + blocks.count * FowFormat.blockSize)
        for (n, block) in blocks.enumerated() {
            let headerIndex = block.x + block.y * FowFormat.tileWidth
            raw[headerIndex * 2] = UInt8(n + 1)
            let start = FowFormat.tileHeaderSize + n * FowFormat.blockSize
            for (x, y) in block.bits { raw[start + y * 8 + x / 8] |= 0x80 >> UInt8(x % 8) }
        }
        let deflated = try (Data(raw) as NSData).compressed(using: .zlib) as Data
        let url = sync.appendingPathComponent(filename(tileID: id))
        try (Data([0x78, 0x9C]) + deflated).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func diffs(event: Int64) throws -> [UInt32: (added: [UInt8]?, removed: [UInt8]?)] {
        let stmt = try store.db.prepare("SELECT block_key, added, removed FROM block_diffs WHERE event_id = ?")
        try stmt.bind([.int(event)])
        var out: [UInt32: (added: [UInt8]?, removed: [UInt8]?)] = [:]
        while try stmt.step() {
            out[UInt32(stmt.int(0))] = (stmt.blob(1).flatMap(DiffCodec.decode), stmt.blob(2).flatMap(DiffCodec.decode))
        }
        return out
    }

    func testBaselineThenUpdates() throws {
        let tileA = 1, tileB = 2
        try writeTile(id: tileA, blocks: [(3, 5, [(0, 0), (1, 0)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))

        // 1 回目：全量を baseline として記録
        guard case let .recorded(baseID, added, removed) = try recorder.checkOnce() else { return XCTFail() }
        XCTAssertEqual(added, 2); XCTAssertEqual(removed, 0)
        let keyA = FogData.blockKey(1 * 128 + 3, 5)
        XCTAssertEqual(try diffs(event: baseID)[keyA]?.added.map(DiffCodec.bitCount), 2)
        XCTAssertTrue(try store.hasBaseline())
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("backups").path)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].hasSuffix(".zip"))

        // 2 回目：変化なし
        clock += 900
        XCTAssertEqual(try recorder.checkOnce(), .unchanged)

        // 3 回目：ビット (0,0) を消し、(5,5) を足す
        clock += 900
        try writeTile(id: tileA, blocks: [(3, 5, [(1, 0), (5, 5)])], mtime: Date(timeIntervalSince1970: 1_700_100_000))
        guard case let .recorded(id3, a3, r3) = try recorder.checkOnce() else { return XCTFail() }
        XCTAssertEqual(a3, 1); XCTAssertEqual(r3, 1)
        let d3 = try XCTUnwrap(try diffs(event: id3)[keyA])
        XCTAssertEqual(d3.added?[5 * 8 + 0], 0b0000_0100)   // (5, 5)
        XCTAssertEqual(d3.removed?[0], 0b1000_0000)          // (0, 0)

        // 時刻の手がかりが残っていること
        let ev = try store.db.prepare("SELECT kind, prev_checked_at, file_mtime_max FROM events WHERE id = ?")
        try ev.bind([.int(id3)])
        XCTAssertTrue(try ev.step())
        XCTAssertEqual(ev.text(0), "update")
        XCTAssertEqual(ev.real(1), clock.timeIntervalSince1970 - 900)
        XCTAssertEqual(ev.real(2), 1_700_100_000)

        // 4 回目：タイル B が増え、タイル A が消える
        clock += 900
        try writeTile(id: tileB, blocks: [(0, 0, [(7, 7)])], mtime: Date(timeIntervalSince1970: 1_700_200_000))
        try FileManager.default.removeItem(at: sync.appendingPathComponent(filename(tileID: tileA)))
        guard case let .recorded(id4, a4, r4) = try recorder.checkOnce() else { return XCTFail() }
        XCTAssertEqual(a4, 1); XCTAssertEqual(r4, 2)
        XCTAssertNil(try diffs(event: id4)[keyA]?.added)
        XCTAssertTrue(try store.currentBlocks(tileX: 1, tileY: 0).isEmpty)
        XCTAssertEqual(try store.currentBlocks(tileX: 2, tileY: 0).count, 1)

        // 5 回目：もう変化なし
        clock += 900
        XCTAssertEqual(try recorder.checkOnce(), .unchanged)

        let summary = try store.summary()
        XCTAssertEqual(summary.updateCount, 2)
        XCTAssertEqual(summary.bitsAddedSinceBaseline, 2)
    }

    func testRewriteWithSameBitsRecordsNoEvent() throws {
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try recorder.checkOnce()
        clock += 900
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0)])], mtime: Date(timeIntervalSince1970: 1_700_500_000))
        XCTAssertEqual(try recorder.checkOnce(), .filesChangedWithoutBitDiff)
        // ファイル情報は更新され、次は unchanged になる
        clock += 900
        XCTAssertEqual(try recorder.checkOnce(), .unchanged)
    }

    func testWaitsUntilListingSettles() throws {
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try recorder.checkOnce()

        // 変化を見つけた後、1 回目の再確認で別の変化が入り、その後は落ち着く
        recorder.options.settleInterval = 120
        recorder.options.pollInterval = 30
        var polls = 0
        recorder.sleep = { [unowned self] seconds in
            clock += seconds
            polls += 1
            if polls == 1 {
                try? writeTile(id: 2, blocks: [(0, 0, [(1, 1)])], mtime: Date(timeIntervalSince1970: 1_700_000_100))
            }
        }
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0), (2, 2)])], mtime: Date(timeIntervalSince1970: 1_700_000_050))
        guard case let .recorded(_, added, _) = try recorder.checkOnce() else { return XCTFail() }
        // 待っている間に増えたタイル 2 の分も 1 回にまとまる
        XCTAssertEqual(added, 2)
        // 最後の変化から 120 秒（30 秒 × 4 回）待ってから記録している
        XCTAssertEqual(polls, 5)
    }
}

final class GPXTests: XCTestCase {
    func testParseTimeVariants() throws {
        let base = try XCTUnwrap(GPXReader.parseTime("2020-03-01T02:12:00"))
        XCTAssertEqual(base.timeIntervalSince1970, 1_583_028_720)            // タイムゾーンなし → UTC
        XCTAssertEqual(GPXReader.parseTime("2020-03-01T02:12:00Z"), base)
        XCTAssertEqual(GPXReader.parseTime("2020-03-01T11:12:00+09:00"), base)
        XCTAssertEqual(GPXReader.parseTime("2020-03-01T11:12:00+0900"), base)
        XCTAssertEqual(try XCTUnwrap(GPXReader.parseTime("2020-03-01T02:12:00.250000")).timeIntervalSince1970,
                       1_583_028_720.25, accuracy: 0.0001)
        XCTAssertNil(GPXReader.parseTime("yesterday"))
    }

    func testReadPointsWithTimeOnly() {
        let gpx = """
        <?xml version="1.0"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="35.0" lon="139.0"><time>2020-01-01T00:00:00Z</time></wpt>
          <trk><trkseg>
            <trkpt lat="35.1" lon="139.1"><ele>10</ele><time>2020-01-02T00:00:00Z</time></trkpt>
            <trkpt lat="35.2" lon="139.2"></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let points = GPXReader.read(data: Data(gpx.utf8))
        XCTAssertEqual(points.count, 2)  // 時刻のない地点は除く
        XCTAssertEqual(points[1].lat, 35.1)
    }

    func testBitProjectionMatchesFogGrid() {
        // 経度 0・緯度 0 は世界の中央
        let center = GPXBackfill.bit(lat: 0, lon: 0)
        XCTAssertEqual(center.x, 1 << 21)
        XCTAssertEqual(center.y, 1 << 21)
        // FogData の緯度計算と往復する
        let b = GPXBackfill.bit(lat: 35.681, lon: 139.767)
        let lat = FogData.latitude(ofBlockY: Double(b.y) / Double(FowFormat.bitmapWidth))
        XCTAssertEqual(lat, 35.681, accuracy: 0.001)
    }
}

final class GPXBackfillTests: XCTestCase {
    var tmp: URL!
    var store: HistoryStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("FogBackfillTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = try HistoryStore(url: tmp.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 東京駅付近のビットを中心に、ビット (dx, dy) ずらした位置を baseline に入れる。
    func seedBaseline(_ offsets: [(Int, Int)]) throws -> (x: Int, y: Int) {
        let c = GPXBackfill.bit(lat: 35.681, lon: 139.767)
        var blocks: [UInt32: [UInt8]] = [:]
        for (dx, dy) in offsets {
            let gx = c.x + dx, gy = c.y + dy
            let key = FogData.blockKey(gx / 64, gy / 64)
            var bm = blocks[key] ?? [UInt8](repeating: 0, count: 512)
            bm[(gy % 64) * 8 + (gx % 64) / 8] |= 0x80 >> UInt8(gx % 8)
            blocks[key] = bm
        }
        var change = SyncChange(kind: .baseline, detectedAt: Date(timeIntervalSince1970: 1_800_000_000))
        HistoryRecorder.diff(old: [:], new: blocks, into: &change)
        try store.apply(change, backupName: nil)
        return c
    }

    /// ビット (x, y) の中心の緯度経度。
    func latLon(_ x: Int, _ y: Int) -> (Double, Double) {
        let w = Double(1 << 22)
        let lon = (Double(x) + 0.5) / w * 360 - 180
        let n = Double.pi - 2 * Double.pi * (Double(y) + 0.5) / w
        return (atan(sinh(n)) * 180 / .pi, lon)
    }

    func point(_ x: Int, _ y: Int, _ t: TimeInterval) -> GPXReader.Point {
        let (lat, lon) = latLon(x, y)
        return GPXReader.Point(lat: lat, lon: lon, time: Date(timeIntervalSince1970: t))
    }

    func testAssignsEarliestNearbyTimeAndGroupsByDay() throws {
        // baseline: 中心、右に 2、右に 10 の 3 ビット
        let c = try seedBaseline([(0, 0), (2, 0), (10, 0)])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day1 = 1_600_000_000.0 - 1_600_000_000.0.truncatingRemainder(dividingBy: 86_400)
        let points = [
            point(c.x, c.y, day1 + 3600 * 5),          // 中心：1 日目 5 時
            point(c.x, c.y, day1 + 86_400 * 3),         // 中心：3 日後（遅いので使われない）
            point(c.x + 1, c.y, day1 + 3600 * 9),       // 右 2 のビットから 1 ビット：1 日目 9 時
            point(c.x + 50, c.y, day1),                 // どのビットからも遠い：使われない
        ]
        var backfill = GPXBackfill()
        backfill.calendar = utc
        let r = try backfill.run(points: points, store: store)
        XCTAssertEqual(r.baselineBits, 3)
        XCTAssertEqual(r.assignedBits, 2)   // 中心と右 2。右 10 は半径 2 の外
        XCTAssertEqual(r.dayCount, 1)
        XCTAssertEqual(r.earliest?.timeIntervalSince1970, day1 + 3600 * 5)

        let s = try store.summary()
        XCTAssertEqual(s.backfillDays, 1)
        XCTAssertEqual(s.backfillBits, 2)
        XCTAssertEqual(s.backfillEarliest?.timeIntervalSince1970, day1 + 3600 * 5)
        // baseline と update の集計には混ざらない
        XCTAssertEqual(s.updateCount, 0)

        // 再実行すると置き換わる（増えない）
        let again = try backfill.run(points: [point(c.x + 10, c.y, day1 + 86_400 * 5)], store: store)
        XCTAssertEqual(again.assignedBits, 1)
        XCTAssertEqual(try store.summary().backfillBits, 1)
        XCTAssertEqual(try store.summary().backfillDays, 1)
    }

    func testRerunKeepsBackfillFromOtherSources() throws {
        let c = try seedBaseline([(0, 0), (5, 0)])
        // 手作業で足した推測（出どころ "manual"）
        let key = FogData.blockKey((c.x + 5) / 64, c.y / 64)
        var bm = [UInt8](repeating: 0, count: 512)
        bm[(c.y % 64) * 8 + ((c.x + 5) % 64) / 8] |= 0x80 >> UInt8((c.x + 5) % 8)
        try store.replaceBackfill(sources: ["manual"], events: [.init(at: Date(timeIntervalSince1970: 1_500_000_000), bitsAdded: 1,
            diffs: [.init(blockKey: key, added: DiffCodec.encode(bm), removed: nil)])])
        // 地点からの埋め合わせを 2 回実行しても、manual の分は残る
        for _ in 0..<2 { _ = try GPXBackfill().run(points: [point(c.x, c.y, 1_600_000_000)], store: store) }
        let s = try store.summary()
        XCTAssertEqual(s.backfillBits, 2)
        XCTAssertEqual(s.backfillEarliest?.timeIntervalSince1970, 1_500_000_000)
    }
}

final class TimelineJSONReaderTests: XCTestCase {
    func testIOSExportFormat() throws {
        let json = """
        [
          {"startTime": "2020-03-01T01:00:00.000Z", "endTime": "2020-03-01T03:00:00.000Z",
           "timelinePath": [{"point": "geo:35.681200,139.767100", "durationMinutesOffsetFromStartTime": "72"}]},
          {"startTime": "2020-03-01T11:31:20.000+09:00", "endTime": "2020-03-01T13:04:50.000+09:00",
           "visit": {"topCandidate": {"placeLocation": "geo:35.685200,139.752800"}}},
          {"startTime": "2020-03-01T13:04:50.000+09:00", "endTime": "2020-03-01T13:52:22.000+09:00",
           "activity": {"start": "geo:35.685200,139.752800", "end": "geo:35.690900,139.700300"}},
          {"startTime": "2020-03-07T09:00:00.000+09:00", "endTime": "2020-03-08T18:00:00.000+09:00",
           "timelineMemory": {"distanceFromOriginKms": "50"}}
        ]
        """
        let points = TimelineJSONReader.read(data: Data(json.utf8))
        XCTAssertEqual(points.count, 4)  // 経路 1・滞在 1・移動の始点と終点 2（memory は位置なし）
        XCTAssertEqual(points[0].lat, 35.6812)
        // 経路の点は startTime + 72 分
        XCTAssertEqual(points[0].time, GPXReader.parseTime("2020-03-01T02:12:00Z"))
        // 滞在は startTime（+09:00）
        XCTAssertEqual(points[1].time, GPXReader.parseTime("2020-03-01T02:31:20Z"))
        // 移動の終点は endTime
        XCTAssertEqual(points[3].time, GPXReader.parseTime("2020-03-01T04:52:22Z"))
        XCTAssertEqual(points[3].lon, 139.7003)
    }

    func testAndroidExportFormat() {
        let json = """
        {"semanticSegments": [
          {"startTime": "2024-01-01T10:00:00.000+09:00", "endTime": "2024-01-01T11:00:00.000+09:00",
           "timelinePath": [{"point": "35.6812°, 139.7671°", "time": "2024-01-01T10:05:00.000+09:00"}]},
          {"startTime": "2024-01-01T12:00:00.000+09:00", "endTime": "2024-01-01T13:00:00.000+09:00",
           "visit": {"topCandidate": {"placeLocation": {"latLng": "35.0°, 135.0°"}}}}
        ]}
        """
        let points = TimelineJSONReader.read(data: Data(json.utf8))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].lat, 35.6812)
        XCTAssertEqual(points[0].lon, 139.7671)
        XCTAssertEqual(points[0].time, GPXReader.parseTime("2024-01-01T01:05:00Z"))
        XCTAssertEqual(points[1].lon, 135.0)
    }

    func testImportedPointsReadsBothFormatsFromFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FogImports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("""
        <gpx><trk><trkseg><trkpt lat="35" lon="139"><time>2020-01-01T00:00:00Z</time></trkpt></trkseg></trk></gpx>
        """.utf8).write(to: dir.appendingPathComponent("a.gpx"))
        try Data("""
        [{"startTime": "2020-01-02T00:00:00Z", "endTime": "2020-01-02T01:00:00Z",
          "visit": {"topCandidate": {"placeLocation": "geo:35.1,139.1"}}}]
        """.utf8).write(to: dir.appendingPathComponent("b.json"))
        try Data("not a track".utf8).write(to: dir.appendingPathComponent("c.txt"))

        let (points, sources) = GPXBackfill.importedPoints(folders: [dir, dir.appendingPathComponent("missing")])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(sources.map(\.name), ["a.gpx", "b.json"])
    }
}

extension HistoryRecorderTests {
    func testDefersWhileFolderIsTemporarilyEmptied() throws {
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0), (5, 5)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))
        try writeTile(id: 2, blocks: [(0, 0, [(1, 1)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try recorder.checkOnce()

        // 同期の途中でフォルダが空になる → 見送る
        clock += 900
        for id in [1, 2] { try FileManager.default.removeItem(at: sync.appendingPathComponent(filename(tileID: id))) }
        XCTAssertEqual(try recorder.checkOnce(), .deferredDrasticRemoval(removedFiles: 2, previousFiles: 2))
        clock += 900
        XCTAssertEqual(try recorder.checkOnce(), .deferredDrasticRemoval(removedFiles: 2, previousFiles: 2))

        // 入れ直された（誤記録の (5,5) だけ消えている）→ 正味の差分だけを記録
        clock += 900
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0)])], mtime: Date(timeIntervalSince1970: 1_700_100_000))
        try writeTile(id: 2, blocks: [(0, 0, [(1, 1)])], mtime: Date(timeIntervalSince1970: 1_700_100_000))
        guard case let .recorded(_, added, removed) = try recorder.checkOnce() else { return XCTFail() }
        XCTAssertEqual(added, 0)
        XCTAssertEqual(removed, 1)
        XCTAssertNil(try store.meta("drastic_removal_since"))
    }

    func testAcceptsDrasticRemovalAfterGrace() throws {
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try recorder.checkOnce()
        clock += 900
        try FileManager.default.removeItem(at: sync.appendingPathComponent(filename(tileID: 1)))
        XCTAssertEqual(try recorder.checkOnce(), .deferredDrasticRemoval(removedFiles: 1, previousFiles: 1))
        clock += 7 * 3600
        guard case let .recorded(_, _, removed) = try recorder.checkOnce() else { return XCTFail() }
        XCTAssertEqual(removed, 1)
    }

    func testCollapseAndPurgeRemovesFalseRecordFromWholeHistory() throws {
        // baseline: A(0,0) B(1,0) と誤記録 F(5,5)
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0), (1, 0), (5, 5)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))
        guard case let .recorded(baseID, _, _) = try recorder.checkOnce() else { return XCTFail() }
        // update1: 別タイルに C
        clock += 900
        try writeTile(id: 2, blocks: [(0, 0, [(2, 2)])], mtime: Date(timeIntervalSince1970: 1_700_000_100))
        guard case let .recorded(update1, _, _) = try recorder.checkOnce() else { return XCTFail() }
        // 過去の分の埋め合わせ：A と F に日時
        let keyA = FogData.blockKey(128, 0)
        var bf = [UInt8](repeating: 0, count: 512); bf[0] = 0b1000_0000; bf[5 * 8] = 0b0000_0100
        try store.replaceBackfill(sources: ["timeline"], events: [.init(at: Date(timeIntervalSince1970: 1_600_000_000), bitsAdded: 2,
            diffs: [.init(blockKey: keyA, added: DiffCodec.encode(bf), removed: nil)])])

        // 同期の途中で全部消え（見送らずに記録させる）、F 以外が入れ直された
        recorder.options.drasticRemovalGrace = 0
        clock += 900
        for id in [1, 2] { try FileManager.default.removeItem(at: sync.appendingPathComponent(filename(tileID: id))) }
        guard case let .recorded(wipe, _, wipeRemoved) = try recorder.checkOnce() else { return XCTFail() }
        XCTAssertEqual(wipeRemoved, 4)
        clock += 900
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0), (1, 0)])], mtime: Date(timeIntervalSince1970: 1_700_200_000))
        try writeTile(id: 2, blocks: [(0, 0, [(2, 2)])], mtime: Date(timeIntervalSince1970: 1_700_200_000))
        guard case let .recorded(readd, readdAdded, _) = try recorder.checkOnce() else { return XCTFail() }
        XCTAssertEqual(readdAdded, 3)

        let result = try store.collapseAndPurge(eventIDs: [wipe, readd])
        XCTAssertEqual(result, .init(collapsedEvents: 2, purgedBits: 1, netAddedBits: 0, deletedEmptyEvents: 0))
        XCTAssertEqual(try store.icloudEventIDs(), [baseID, update1])
        // baseline から F が消え、A・B だけ
        XCTAssertEqual(try store.eventDiffs(baseID)[keyA]?.added.map(DiffCodec.bitCount), 2)
        let ev = try store.db.prepare("SELECT bits_added FROM events WHERE id = ?")
        try ev.bind([.int(baseID)]); _ = try ev.step()
        XCTAssertEqual(ev.int(0), 2)
        // 埋め合わせからも F が消え、A だけ
        XCTAssertEqual(try store.summary().backfillBits, 1)
        // 履歴を重ねた状態が、今の状態（current_blocks）と一致する
        let replayed = try store.replay(try store.icloudEventIDs())
        XCTAssertEqual(replayed, try store.currentBlocks(tileX: 1, tileY: 0).merging(try store.currentBlocks(tileX: 2, tileY: 0)) { a, _ in a })
    }

    func testCollapseRejectsNonConsecutiveEvents() throws {
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))
        guard case let .recorded(baseID, _, _) = try recorder.checkOnce() else { return XCTFail() }
        clock += 900
        try writeTile(id: 2, blocks: [(0, 0, [(1, 1)])], mtime: Date(timeIntervalSince1970: 1_700_000_100))
        _ = try recorder.checkOnce()
        clock += 900
        try writeTile(id: 3, blocks: [(0, 0, [(2, 2)])], mtime: Date(timeIntervalSince1970: 1_700_000_200))
        guard case let .recorded(third, _, _) = try recorder.checkOnce() else { return XCTFail() }
        XCTAssertThrowsError(try store.collapseAndPurge(eventIDs: [baseID, third]))
    }
}

extension GPXBackfillTests {
    func testLinePropagationTakesNearestAndRespectsReach() throws {
        // 横一列 0..<20 の線。左端 0 と右端 19 に地点がある。
        let c = try seedBaseline((0..<20).map { ($0, 0) })
        let tLeft = 1_600_000_000.0, tRight = tLeft + 86_400 * 10
        let points = [point(c.x, c.y, tLeft), point(c.x + 19, c.y, tRight)]
        var backfill = GPXBackfill()
        backfill.radius = 0
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        backfill.calendar = utc

        backfill.lineReach = 0
        XCTAssertEqual(try backfill.run(points: points, store: store).assignedBits, 2)

        backfill.lineReach = 3
        let short = try backfill.run(points: points, store: store)
        XCTAssertEqual(short.timelineBits, 2)
        XCTAssertEqual(short.lineBits, 6)        // 両端から 3 ビットずつ

        backfill.lineReach = 100
        let full = try backfill.run(points: points, store: store)
        XCTAssertEqual(full.assignedBits, 20)
        XCTAssertEqual(full.dayCount, 2)          // 左半分は左端の日、右半分は右端の日
        XCTAssertEqual(try store.summary().backfillBits, 20)
    }

}


extension HistoryRecorderTests {
    func testTimelapseOrdersBackfillBeforeBaselineAndHandlesRemoval() throws {
        // baseline（時刻 T0）: A(0,0) B(1,0)
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0), (1, 0)])], mtime: Date(timeIntervalSince1970: 1_700_000_000))
        let t0 = clock
        _ = try recorder.checkOnce()
        // 埋め合わせ：A は T0 より前（Tb）に行っていた
        let tb = Date(timeIntervalSince1970: 1_500_000_000)
        let key = FogData.blockKey(128, 0)
        var bm = [UInt8](repeating: 0, count: 512); bm[0] = 0b1000_0000
        try store.replaceBackfill(sources: ["timeline"], events: [.init(at: tb, bitsAdded: 1,
            diffs: [.init(blockKey: key, added: DiffCodec.encode(bm), removed: nil)])])
        // update（T1）: B が消え、C(2,0) が増える
        clock += 900
        let t1 = clock
        try writeTile(id: 1, blocks: [(0, 0, [(0, 0), (2, 0)])], mtime: Date(timeIntervalSince1970: 1_700_100_000))
        _ = try recorder.checkOnce()

        let data = try TimelapseData.load(from: store)
        XCTAssertEqual(data.steps.map(\.time), [tb, t0, t1])
        XCTAssertEqual(data.steps.map(\.added.count), [1, 1, 1])   // T0 では B だけが新しい（A は既に晴れている）
        XCTAssertEqual(data.steps.map(\.removed.count), [0, 0, 1])

        var cursor = TimelapseCursor(data: data)
        cursor.move(to: tb)
        XCTAssertEqual(cursor.visibleBits, 1)
        cursor.move(to: t1)
        XCTAssertEqual(cursor.visibleBits, 2)   // A と C（B は消えた）
        XCTAssertEqual(cursor.nextStepTime, nil)
        cursor.move(to: t0)                     // 巻き戻し
        XCTAssertEqual(cursor.visibleBits, 2)   // A と B
        XCTAssertEqual(cursor.fogData.blocks.count, 1)
        XCTAssertGreaterThan(cursor.areaKm2, 0)
        cursor.move(to: tb - 1)
        XCTAssertEqual(cursor.visibleBits, 0)
        XCTAssertEqual(cursor.areaKm2, 0, accuracy: 1e-12)
    }
}
