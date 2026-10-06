import Foundation

/// タイムラプス用に、履歴を「いつ、どのビットが晴れた・霧に戻った」の時刻順の並びにしたもの。
///
/// 各ビットは、過去の分の埋め合わせ（backfill）と iCloud の記録（baseline / update）のうち、
/// 早い方の時刻に晴れる。iCloud の記録で消えたビットは、その時刻に霧に戻る。
struct TimelapseData {
    struct Step {
        var time: Date
        var added: [UInt64]
        var removed: [UInt64]
    }

    let steps: [Step]

    var start: Date? { steps.first?.time }
    var end: Date? { steps.last?.time }

    /// 世界座標のビット (x, y) を 1 つの数にする。
    static func key(_ x: Int, _ y: Int) -> UInt64 { UInt64(UInt32(x)) << 32 | UInt64(UInt32(y)) }

    static func load(from store: HistoryStore) throws -> TimelapseData {
        struct Op { var time: Double; var add: Bool; var bit: UInt64; var order: Int }
        var ops: [Op] = []
        let events = try store.db.prepare("SELECT id, kind, detected_at FROM events ORDER BY detected_at, id")
        var list: [(id: Int64, kind: String, time: Double)] = []
        while try events.step() { list.append((events.int(0), events.text(1) ?? "", events.real(2) ?? 0)) }
        for (order, e) in list.enumerated() {
            for (key, diff) in try store.eventDiffs(e.id) {
                if let a = diff.added { for b in bits(a, key) { ops.append(Op(time: e.time, add: true, bit: b, order: order)) } }
                if let r = diff.removed, e.kind != "backfill" {
                    for b in bits(r, key) { ops.append(Op(time: e.time, add: false, bit: b, order: order)) }
                }
            }
        }
        ops.sort { ($0.time, $0.order) < ($1.time, $1.order) }

        // 状態が実際に変わった分だけを、時刻ごとの段にまとめる
        var visible = Set<UInt64>()
        var steps: [Step] = []
        for op in ops {
            let changed = op.add ? visible.insert(op.bit).inserted : visible.remove(op.bit) != nil
            guard changed else { continue }
            let t = Date(timeIntervalSince1970: op.time)
            if steps.last?.time != t { steps.append(Step(time: t, added: [], removed: [])) }
            if op.add { steps[steps.count - 1].added.append(op.bit) } else { steps[steps.count - 1].removed.append(op.bit) }
        }
        return TimelapseData(steps: steps)
    }

    private static func bits(_ bitmap: [UInt8], _ blockKey: UInt32) -> [UInt64] {
        let bx = Int(blockKey >> 16), by = Int(blockKey & 0xFFFF)
        var out: [UInt64] = []
        for (i, byte) in bitmap.enumerated() where byte != 0 {
            let y = i / 8, xBase = (i % 8) * 8
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                out.append(key(bx * 64 + xBase + bit, by * 64 + y))
            }
        }
        return out
    }
}

/// タイムラプスの再生位置。段を順に当てて、その時点の霧を作る。巻き戻しは最初から当て直す。
struct TimelapseCursor {
    let data: TimelapseData
    /// 当て終わった段の数。
    private(set) var applied = 0
    private(set) var blocks: [UInt32: [UInt8]] = [:]
    /// 晴れているビットの数と、その面積（km²）。
    private(set) var visibleBits = 0
    private(set) var areaKm2 = 0.0

    init(data: TimelapseData) { self.data = data }

    /// `time` までの段を当てる。新しく晴れたビットを返す（地図の追跡用）。
    @discardableResult
    mutating func move(to time: Date) -> [UInt64] {
        if applied > 0, data.steps[applied - 1].time > time { reset() }
        var newlyAdded: [UInt64] = []
        while applied < data.steps.count, data.steps[applied].time <= time {
            let step = data.steps[applied]
            for b in step.added { set(b, true) }
            for b in step.removed { set(b, false) }
            newlyAdded += step.added
            applied += 1
        }
        return newlyAdded
    }

    /// 次の段の時刻（変化のない期間を飛ばすのに使う）。
    var nextStepTime: Date? { applied < data.steps.count ? data.steps[applied].time : nil }

    var fogData: FogData { FogData(blocks: blocks.mapValues { FogBlock(bitmap: $0) }) }

    private mutating func reset() {
        applied = 0
        blocks = [:]
        visibleBits = 0
        areaKm2 = 0
    }

    private static let equatorBitKm2: Double = {
        let side = 40_075_016.686 / Double(1 << FowFormat.worldBitsLog2) / 1000
        return side * side
    }()

    private static let emptyBlock = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)

    private mutating func set(_ bit: UInt64, _ on: Bool) {
        let x = Int(bit >> 32), y = Int(bit & 0xFFFF_FFFF)
        let key = FogData.blockKey(x / 64, y / 64)
        let index = (y % 64) * 8 + (x % 64) / 8
        let mask: UInt8 = 0x80 >> UInt8(x % 8)
        // 取り出して書き戻すとブロックがまるごと複製されるので、辞書の中で直接書き換える。
        if on {
            guard (blocks[key]?[index] ?? 0) & mask == 0 else { return }
            blocks[key, default: Self.emptyBlock][index] |= mask
        } else {
            guard let byte = blocks[key]?[index], byte & mask != 0 else { return }
            blocks[key]![index] = byte & ~mask
            if blocks[key]!.allSatisfy({ $0 == 0 }) { blocks[key] = nil }
        }
        let lat = FogData.latitude(ofBlockY: Double(y) / 64)
        let area = Self.equatorBitKm2 * pow(cos(lat * .pi / 180), 2)
        visibleBits += on ? 1 : -1
        areaKm2 += on ? area : -area
    }
}
