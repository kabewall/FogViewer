import Foundation

/// 世界の霧のパスポートにならった、マス目で描く地域の縮図。
///
/// 各マスの中心がどの地域に入るかを境界から調べて塗る。
/// - 世界・大陸：国ごと
/// - 子を持つ地域（日本・都道府県・政令指定都市）：子ごと
/// - 子を持たない地域（市区町村、日本以外の国）：その地域と、マスごとの晴れたビットの量
struct PixelMap {
    static let sea: Int32 = -1
    /// 範囲の外の陸（隣の国や市区町村）。
    static let otherLand: Int32 = -2

    let cols: Int
    let rows: Int
    let frame: BitRect
    /// マスごとの地域の番号。負なら `sea` か `otherLand`。
    let cells: [Int32]
    /// マスごとの晴れたビットの数（子を持たない地域のときだけ）。
    let heat: [Int]?
    /// 地域ごとの名札の位置（マスの列・行、マスの中心）。大陸のページだけ。
    let labels: [Int: (col: Int, row: Int)]
    /// 世界のページの、大陸ごとの行った国の数と吹き出しの位置（マスの列・行の単位）。
    let bubbles: [(index: Int, count: Int, col: Double, row: Double)]
    /// 子を持たない地域（市区町村、日本以外の国）のページか。マスを晴れた量で塗る。
    let isLeaf: Bool
    /// 国ごとに塗るページ（世界・大陸）か。
    let showsCountries: Bool

    func value(col: Int, row: Int) -> Int32 { cells[row * cols + col] }

    /// 長い辺のマスの数。
    static let resolution = 64

    static func build(parent: Int?, catalog: RegionCatalog, stats: RegionStats, fog: FogData) -> PixelMap {
        let frame = Self.frame(parent: parent, catalog: catalog, stats: stats)
        let side = max(frame.maxX - frame.minX, frame.maxY - frame.minY) / Double(resolution)
        let cols = max(1, Int(((frame.maxX - frame.minX) / side).rounded()))
        let rows = max(1, Int(((frame.maxY - frame.minY) / side).rounded()))
        let isLeaf = parent.map { catalog.children[$0].isEmpty } ?? false
        let showsCountries = parent == nil || catalog.regions[parent!].level == .continent
        let scope = scopeLookup(parent: parent, catalog: catalog)

        var cells = [Int32](repeating: sea, count: cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let x = frame.minX + (Double(col) + 0.5) * side
                let y = frame.minY + (Double(row) + 0.5) * side
                cells[row * cols + col] = scope(x, y)
            }
        }

        var heat: [Int]?
        if isLeaf, let parent {
            heat = Self.countBits(in: parent, fog: fog, frame: frame, side: side, cols: cols, rows: rows, cells: cells)
        }

        var labels: [Int: (col: Int, row: Int)] = [:]
        var bubbles: [(index: Int, count: Int, col: Double, row: Double)] = []
        if parent == nil {
            for c in catalog.regions.indices where catalog.regions[c].level == .continent {
                guard let place = bubblePlaces[catalog.regions[c].code] else { continue }
                let b = RegionCatalog.bitPoint(lon: place.lon, lat: place.lat)
                let count = catalog.children[c].filter { stats.entry($0).bits > 0 }.count
                bubbles.append((c, count, (b.x - frame.minX) / side, (b.y - frame.minY) / side))
            }
        } else if showsCountries {
            labels = countryLabels(parent: parent!, cells: cells, cols: cols, frame: frame, side: side, catalog: catalog)
        }
        return PixelMap(cols: cols, rows: rows, frame: frame, cells: cells, heat: heat, labels: labels,
                        bubbles: bubbles, isLeaf: isLeaf, showsCountries: showsCountries)
    }

    /// 大陸の吹き出しの位置（経度・緯度）。国の位置から求めると、ロシアのような大きな国に引っ張られるので決めておく。
    private static let bubblePlaces: [String: (lon: Double, lat: Double)] = [
        "AS": (95, 45), "EU": (15, 50), "AF": (20, 5), "NA": (-100, 45),
        "SA": (-60, -15), "OC": (135, -25), "AN": (0, -54), "SS": (-35, -35),
    ]

    /// 国の名札の位置。その国のマスの重心にいちばん近いマスに置く。
    private static func countryLabels(parent: Int, cells: [Int32], cols: Int, frame: BitRect, side: Double,
                                      catalog: RegionCatalog) -> [Int: (col: Int, row: Int)] {
        var sumX: [Int: Double] = [:], sumY: [Int: Double] = [:], count: [Int: Double] = [:]
        for (i, v) in cells.enumerated() where v >= 0 {
            let k = Int(v)
            sumX[k, default: 0] += Double(i % cols)
            sumY[k, default: 0] += Double(i / cols)
            count[k, default: 0] += 1
        }
        var labels: [Int: (col: Int, row: Int)] = [:]
        var bestDistance: [Int: Double] = [:]
        for (i, v) in cells.enumerated() where v >= 0 {
            let k = Int(v)
            let n = count[k]!
            let dx = Double(i % cols) - sumX[k]! / n
            let dy = Double(i / cols) - sumY[k]! / n
            let d = dx * dx + dy * dy
            if d < bestDistance[k] ?? .infinity {
                bestDistance[k] = d
                labels[k] = (i % cols, i / cols)
            }
        }
        // マスに当たらないほど小さい国（島国など）は、範囲の中なら外接長方形の中心に置く
        for i in catalog.children[parent] where labels[i] == nil && catalog.regions[i].level == .country {
            let b = catalog.regions[i].mainBounds
            guard !b.isNull, frame.contains(x: b.midX, y: b.midY) else { continue }
            labels[i] = (Int((b.midX - frame.minX) / side), Int((b.midY - frame.minY) / side))
        }
        return labels
    }

    /// マスの中心を、この縮図で塗り分ける地域の番号に変える関数。
    private static func scopeLookup(parent: Int?, catalog: RegionCatalog) -> (Double, Double) -> Int32 {
        guard let parent else {
            return { x, y in catalog.country(atX: x, y: y).map(Int32.init) ?? sea }
        }
        let region = catalog.regions[parent]
        if region.level == .continent {
            return { x, y in
                guard let c = catalog.country(atX: x, y: y) else { return sea }
                return catalog.regions[c].parent == parent ? Int32(c) : otherLand
            }
        }
        // 子があれば子で、なければ自分で塗る
        let inner = catalog.children[parent].isEmpty ? [parent] : catalog.children[parent]
        var country = parent
        while catalog.regions[country].level != .country, let p = catalog.regions[country].parent { country = p }
        return { x, y in
            if let hit = inner.first(where: { RegionCatalog.contains(catalog.regions[$0], x: x, y: y) }) { return Int32(hit) }
            // 外側は陸か海か。国・都道府県の輪郭は市区町村より粗く簡略化してあり、海岸沿いのすき間を陸にしてしまうので、
            // 国の中は市区町村の境界で、国の外は国の境界で決める
            if catalog.municipality(atX: x, y: y) != nil { return otherLand }
            if let c = catalog.country(atX: x, y: y), c != country { return otherLand }
            return sea
        }
    }

    /// 縮図に描く範囲。大陸と日本は見慣れた範囲に固定し、それ以外は地域の本体と晴れた範囲に合わせる。
    private static func frame(parent: Int?, catalog: RegionCatalog, stats: RegionStats) -> BitRect {
        func lonLat(_ lon0: Double, _ lat0: Double, _ lon1: Double, _ lat1: Double) -> BitRect {
            let a = RegionCatalog.bitPoint(lon: lon0, lat: lat0), b = RegionCatalog.bitPoint(lon: lon1, lat: lat1)
            return BitRect(minX: a.x, minY: a.y, maxX: b.x, maxY: b.y)
        }
        guard let parent else { return lonLat(-180, 80, 180, -58) }
        let region = catalog.regions[parent]
        switch (region.level, region.code) {
        case (.continent, "AS"): return lonLat(25, 56, 150, -11)
        case (.continent, "EU"): return lonLat(-25, 71, 45, 34)
        case (.continent, "AF"): return lonLat(-20, 38, 55, -36)
        case (.continent, "NA"): return lonLat(-170, 75, -50, 7)
        case (.continent, "SA"): return lonLat(-85, 13, -33, -56)
        case (.continent, "OC"): return lonLat(110, 0, 180, -48)
        case (.continent, "AN"): return lonLat(-180, -60, 180, -80)
        case (.continent, _): return lonLat(-180, 80, 180, -58)
        case (.country, "JPN"): return lonLat(122.5, 45.8, 146.5, 23.8)
        default:
            var b = region.mainBounds.union(stats.entry(parent).visitedBounds)
            if b.isNull { b = region.bounds }
            // 正方形に近づけて少し余白をとる
            let side = max(b.maxX - b.minX, b.maxY - b.minY) * 1.1
            let w = max(side * 0.6, (b.maxX - b.minX) * 1.1), h = max(side * 0.6, (b.maxY - b.minY) * 1.1)
            // 経度 ±180 や極にかかる地域（南極・ロシアなど）で世界の外に出ないように切り詰める
            let world = Double(1 << FowFormat.worldBitsLog2)
            return BitRect(minX: max(0, b.midX - w / 2), minY: max(0, b.midY - h / 2),
                           maxX: min(world, b.midX + w / 2), maxY: min(world, b.midY + h / 2))
        }
    }

    /// 地域の中のマスごとに、晴れたビットを数える。
    private static func countBits(in index: Int, fog: FogData, frame: BitRect, side: Double,
                             cols: Int, rows: Int, cells: [Int32]) -> [Int] {
        var heat = [Int](repeating: 0, count: cols * rows)
        let last = FowFormat.worldBlocks - 1
        let bx0 = max(0, Int(frame.minX) / 64), bx1 = min(last, Int(frame.maxX) / 64)
        let by0 = max(0, Int(frame.minY) / 64), by1 = min(last, Int(frame.maxY) / 64)
        let visit = { (bx: Int, by: Int, block: FogBlock) in
            block.forEachVisited { x, y in
                let row = Int((Double(by * 64 + y) + 0.5 - frame.minY) / side)
                let col = Int((Double(bx * 64 + x) + 0.5 - frame.minX) / side)
                guard row >= 0, row < rows, col >= 0, col < cols, cells[row * cols + col] == Int32(index) else { return }
                heat[row * cols + col] += 1
            }
        }
        // 範囲が狭ければ範囲のブロックを引き、広ければ全ブロックをなめる
        if (bx1 - bx0 + 1) * (by1 - by0 + 1) <= fog.blocks.count {
            for by in by0...by1 { for bx in bx0...bx1 { if let b = fog.block(bx, by) { visit(bx, by, b) } } }
        } else {
            for (key, block) in fog.blocks {
                let bx = Int(key >> 16), by = Int(key & 0xFFFF)
                if bx >= bx0, bx <= bx1, by >= by0, by <= by1 { visit(bx, by, block) }
            }
        }
        return heat
    }
}
