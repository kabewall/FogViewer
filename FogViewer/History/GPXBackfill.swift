import Foundation

/// 霧のビットに「最初に行った日時」を推測してつける（過去の分の埋め合わせ）。
///
/// 確かな順に 2 段階でつけ、どの段階でつけたかを記録の出どころ（source）に残す。
/// 1. `timeline`：取り込んだ時刻つき地点（GPX・Google タイムライン JSON）から `radius` ビット以内。最も早い時刻
/// 2. `line`：1 でついたビットから、つながった線（8 近傍）を `lineReach` ビットまでたどり、一番近いビットの時刻
///
/// 対象は今の霧（current_blocks）すべて。結果は段階ごと・日ごとに 1 件の `backfill` イベントとして保存し、
/// baseline や update のイベントは書き換えない。再実行すると、この 2 段階の backfill だけを消して作り直す
/// （ほかの出どころの backfill、例えば手作業で足した推測は残す）。
struct GPXBackfill {
    struct Result: Equatable {
        var pointCount: Int
        /// 対象にしたビット（今の霧の全部）。
        var baselineBits: Int
        /// 日時をつけたビットの合計。
        var assignedBits: Int
        var timelineBits = 0
        var lineBits = 0
        var dayCount: Int
        var earliest: Date?
        var latest: Date?
    }

    /// 地点から何ビット以内のビットに時刻をつけるか（1 ビット ≒ 8 m）。
    var radius = 2
    /// つながった線を何ビットまでたどるか（625 ビット ≒ 5 km）。0 ならたどらない。
    var lineReach = 625
    var calendar = Calendar.current

    /// この処理が作り直す backfill の出どころ。
    static let managedSources: Set<String> = ["timeline", "line"]

    /// 緯度経度を霧の世界座標（ビット）に直す。FogData と同じ Web メルカトル。
    static func bit(lat: Double, lon: Double) -> (x: Int, y: Int) {
        let w = Double(1 << FowFormat.worldBitsLog2)
        let x = (lon + 180) / 360 * w
        let y = (Double.pi - asinh(tan(lat * .pi / 180))) * w / (2 * Double.pi)
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    private static let emptyBitmap = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)

    private static func key(_ x: Int, _ y: Int) -> UInt64 { UInt64(UInt32(x)) << 32 | UInt64(UInt32(y)) }
    private static func xy(_ k: UInt64) -> (Int, Int) { (Int(k >> 32), Int(k & 0xFFFF_FFFF)) }

    func run(points: [GPXReader.Point], store: HistoryStore) throws -> Result {
        // 対象：今の霧のビット
        var targets = Set<UInt64>()
        let bw = FowFormat.bitmapWidth
        for (blockKey, bitmap) in try store.allCurrentBlocks() {
            let bx = Int(blockKey >> 16), by = Int(blockKey & 0xFFFF)
            for j in 0..<bw {
                for byteIndex in 0..<8 {
                    let byte = bitmap[j * 8 + byteIndex]
                    if byte == 0 { continue }
                    for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                        targets.insert(Self.key(bx * bw + byteIndex * 8 + bit, by * bw + j))
                    }
                }
            }
        }

        // 段階 1：地点の近く
        var pointTime: [UInt64: Double] = [:]
        pointTime.reserveCapacity(points.count)
        for p in points {
            guard abs(p.lat) < 85.05 else { continue }
            let b = Self.bit(lat: p.lat, lon: p.lon)
            let k = Self.key(b.x, b.y)
            let t = p.time.timeIntervalSince1970
            if let old = pointTime[k], old <= t { continue }
            pointTime[k] = t
        }
        var assigned: [UInt64: (time: Double, source: String)] = [:]
        for k in targets {
            let (gx, gy) = Self.xy(k)
            var best: Double?
            for dy in -radius...radius {
                for dx in -radius...radius {
                    if let t = pointTime[Self.key(gx + dx, gy + dy)], best == nil || t < best! { best = t }
                }
            }
            if let best { assigned[k] = (best, "timeline") }
        }

        // 段階 2：つながった線をたどる。同じ距離で複数から届くときは早い時刻を採る。
        if lineReach > 0 {
            var frontier = Array(assigned.keys)
            var step = 0
            while !frontier.isEmpty && step < lineReach {
                step += 1
                var next: [UInt64: Double] = [:]
                for k in frontier {
                    let t = assigned[k]!.time
                    let (x, y) = Self.xy(k)
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let n = Self.key(x + dx, y + dy)
                            guard targets.contains(n), assigned[n] == nil else { continue }
                            if let old = next[n], old <= t { continue }
                            next[n] = t
                        }
                    }
                }
                for (n, t) in next { assigned[n] = (t, "line") }
                frontier = Array(next.keys)
            }
        }

        // 段階・日ごとのイベントにまとめる
        struct DayBlock: Hashable { var source: String; var day: Date; var block: UInt32 }
        var byDay: [DayBlock: [UInt8]] = [:]
        struct DayKey: Hashable { var source: String; var day: Date }
        var firstTime: [DayKey: Double] = [:]
        var result = Result(pointCount: points.count, baselineBits: targets.count, assignedBits: assigned.count, dayCount: 0)
        for (k, a) in assigned {
            let (gx, gy) = Self.xy(k)
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: a.time))
            let blockKey = FogData.blockKey(gx / bw, gy / bw)
            let lx = gx % bw, ly = gy % bw
            byDay[DayBlock(source: a.source, day: day, block: blockKey), default: Self.emptyBitmap][ly * 8 + lx / 8] |= 0x80 >> UInt8(lx % 8)
            let dk = DayKey(source: a.source, day: day)
            firstTime[dk] = min(firstTime[dk] ?? a.time, a.time)
            result.earliest = min(result.earliest ?? Date(timeIntervalSince1970: a.time), Date(timeIntervalSince1970: a.time))
            result.latest = max(result.latest ?? Date(timeIntervalSince1970: a.time), Date(timeIntervalSince1970: a.time))
            if a.source == "timeline" { result.timelineBits += 1 } else { result.lineBits += 1 }
        }
        let grouped = Dictionary(grouping: byDay, by: { DayKey(source: $0.key.source, day: $0.key.day) })
        let events: [HistoryStore.BackfillEvent] = grouped.keys
            .sorted { ($0.day, $0.source) < ($1.day, $1.source) }
            .map { dk in
                let blocks = grouped[dk]!.sorted { $0.key.block < $1.key.block }
                let diffs = blocks.compactMap { entry in
                    DiffCodec.encode(entry.value).map { SyncChange.BlockDiff(blockKey: entry.key.block, added: $0, removed: nil) }
                }
                let bits = blocks.reduce(0) { $0 + DiffCodec.bitCount($1.value) }
                return .init(at: Date(timeIntervalSince1970: firstTime[dk]!), bitsAdded: bits, diffs: diffs, source: dk.source)
            }
        result.dayCount = Set(grouped.keys.map(\.day)).count
        try store.replaceBackfill(sources: Self.managedSources, events: events)
        return result
    }

    /// Fog of World の iCloud の Import フォルダ。読むだけで、書き込まない。
    static var fogImportFolder: URL {
        FogStore.syncFolder.deletingLastPathComponent().appendingPathComponent("Import", isDirectory: true)
    }

    /// このアプリが取り込んだファイルを置くフォルダ。
    static var appImportFolder: URL {
        HistoryStore.defaultDirectory.appendingPathComponent("imports", isDirectory: true)
    }

    struct Source {
        var name: String
        var pointCount: Int
    }

    /// 両方のフォルダの GPX と JSON（Google タイムライン）をすべて読む。
    static func importedPoints(folders: [URL] = [fogImportFolder, appImportFolder]) -> (points: [GPXReader.Point], sources: [Source]) {
        var points: [GPXReader.Point] = []
        var sources: [Source] = []
        for url in files(in: folders, extensions: ["gpx", "json"]) {
            guard let data = HistoryRecorder.read(url) else { continue }
            let read = url.pathExtension.lowercased() == "gpx" ? GPXReader.read(data: data) : TimelineJSONReader.read(data: data)
            guard !read.isEmpty else { continue }
            points += read
            sources.append(Source(name: url.lastPathComponent, pointCount: read.count))
        }
        return (points, sources)
    }

    private static func files(in folders: [URL], extensions: Set<String>) -> [URL] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    /// ファイルをこのアプリの取り込みフォルダにコピーする。同名があれば置き換える。
    @discardableResult
    static func addImportFile(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: appImportFolder, withIntermediateDirectories: true)
        let dest = appImportFolder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}
