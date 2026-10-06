import Foundation
import MapKit

/// 国・都道府県・市区町村の境界。`tools/build_regions.sh` で作った regions.bin を読む。
///
/// 境界は霧と同じ世界座標（ビット単位、Web メルカトル）に直して持つ。
/// 出典：Natural Earth（国）、国土数値情報 行政区域データ N03（日本の都道府県・市区町村）。
final class RegionCatalog: @unchecked Sendable {
    enum Level: UInt8 {
        case country = 0, prefecture, city, municipality
        /// 大陸。輪を持たず、国をまとめるだけ。
        case continent
    }

    struct Region {
        let level: Level
        let parent: Int?
        let code: String
        let name: String
        /// 同じ親の中でのまとまり（国なら「東アジア」などの小地域、都道府県なら地方）。
        let group: String
        /// 国旗用の ISO 3166-1 alpha-2（国以外は空）。
        let flag: String
        let areaKm2: Double
        let rings: [Ring]
        let bounds: BitRect

        /// いちばん大きな輪の範囲（東京都なら島を除いた本土側）。地図を寄せるのに使う。
        var mainBounds: BitRect {
            rings.map(\.bounds).max { ($0.maxX - $0.minX) * ($0.maxY - $0.minY) < ($1.maxX - $1.minX) * ($1.maxY - $1.minY) } ?? bounds
        }
    }

    let regions: [Region]
    /// 子の番号（コード順）。
    let children: [[Int]]
    /// 市区町村（区を含む）の数。子孫に持つものを数える。
    let municipalityCounts: [Int]

    /// ビットの判定に使う地域。日本は市区町村、それ以外は国。
    /// 日本の国の輪郭は、市区町村に入らなかったビット（簡略化した海岸など）の受け皿にする。
    private let detailIndex: TileIndex
    private let countryIndex: TileIndex

    static var bundled: URL? { Bundle(for: RegionCatalog.self).url(forResource: "regions", withExtension: "bin") }

    static func load(url: URL) throws -> RegionCatalog {
        try RegionCatalog(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        var r = ByteReader(data: data)
        guard try r.bytes(4) == Array("FVRG".utf8), try r.u32() == 2 else { throw ParseError.badHeader }
        let count = Int(try r.u32())
        var regions: [Region] = []
        regions.reserveCapacity(count)
        for _ in 0..<count {
            guard let level = Level(rawValue: try r.u8()) else { throw ParseError.badHeader }
            let parent = Int(try r.i32())
            // 親は先に並んでいる（親をたどる処理が範囲外や循環で止まらないように確かめる）
            guard parent < regions.count else { throw ParseError.badParent }
            let code = try r.string(), name = try r.string()
            let group = try r.string(), flag = try r.string()
            let area = try r.f64()
            var rings: [Ring] = []
            for _ in 0..<Int(try r.u32()) {
                let n = Int(try r.u32())
                var xs = [Double](repeating: 0, count: n), ys = [Double](repeating: 0, count: n)
                for i in 0..<n {
                    let lon = Double(try r.i32()) / 1e6, lat = Double(try r.i32()) / 1e6
                    (xs[i], ys[i]) = Self.bitPoint(lon: lon, lat: lat)
                }
                rings.append(Ring(xs: xs, ys: ys))
            }
            let bounds = rings.reduce(BitRect.null) { $0.union($1.bounds) }
            regions.append(Region(level: level, parent: parent >= 0 ? parent : nil, code: code, name: name,
                                  group: group, flag: flag, areaKm2: area, rings: rings, bounds: bounds))
        }
        self.regions = regions

        var children = [[Int]](repeating: [], count: regions.count)
        for (i, region) in regions.enumerated() { if let p = region.parent { children[p].append(i) } }
        self.children = children
        var counts = [Int](repeating: 0, count: regions.count)
        for (i, region) in regions.enumerated() where region.level == .municipality {
            var p = region.parent
            while let q = p { counts[q] += 1; p = regions[q].parent }
            counts[i] = 1
        }
        municipalityCounts = counts

        detailIndex = TileIndex(regions: regions, members: regions.indices.filter { regions[$0].level == .municipality })
        countryIndex = TileIndex(regions: regions, members: regions.indices.filter { regions[$0].level == .country })
    }

    enum ParseError: Error { case badHeader, truncated, badParent }

    /// 経度・緯度を世界座標（ビット単位）にする。極付近はメルカトルで発散するので切り詰める。
    static func bitPoint(lon: Double, lat: Double) -> (x: Double, y: Double) {
        let w = Double(1 << FowFormat.worldBitsLog2)
        let phi = min(max(lat, -85.05), 85.05) * .pi / 180
        return ((lon + 180) / 360 * w, (1 - asinh(tan(phi)) / .pi) / 2 * w)
    }

    // MARK: - 判定

    /// ブロック 1 つの訪問ビットを地域ごとに数える。どこにも入らないビットは nil（海上など）に数える。
    func classify(blockX bx: Int, blockY by: Int, bitmap: [UInt8]) -> [Int?: Int] {
        var bits: [(x: Double, y: Double)] = []
        FogBlock(bitmap: bitmap).forEachVisited { x, y in
            bits.append((Double(bx * 64 + x) + 0.5, Double(by * 64 + y) + 0.5))
        }
        var result: [Int?: Int] = [:]
        guard !bits.isEmpty else { return result }
        let block = BitRect(minX: Double(bx * 64), minY: Double(by * 64), maxX: Double(bx * 64 + 64), maxY: Double(by * 64 + 64))
        let tile = TileIndex.key(bx / FowFormat.tileWidth, by / FowFormat.tileWidth)
        var rest = bits
        for index in [detailIndex, countryIndex] {
            for candidate in index.tiles[tile] ?? [] {
                guard !rest.isEmpty else { break }
                let region = regions[candidate]
                guard region.bounds.intersects(block) else { continue }
                // 境界がブロックにかからなければ、ブロック全体が内か外のどちらか
                let crosses = region.rings.contains { $0.crosses(block) }
                if !crosses {
                    guard Self.contains(region, x: block.midX, y: block.midY) else { continue }
                    result[candidate, default: 0] += rest.count
                    rest = []
                    break
                }
                var outside: [(x: Double, y: Double)] = []
                for p in rest {
                    if Self.contains(region, x: p.x, y: p.y) { result[candidate, default: 0] += 1 } else { outside.append(p) }
                }
                rest = outside
            }
        }
        if !rest.isEmpty { result[nil, default: 0] += rest.count }
        return result
    }

    /// 点がどの国に入るか（地図の縮図を描くのに使う）。
    func country(atX x: Double, y: Double) -> Int? { find(in: countryIndex, x: x, y: y) }

    /// 点がどの市区町村（日本だけ）に入るか。
    func municipality(atX x: Double, y: Double) -> Int? { find(in: detailIndex, x: x, y: y) }

    private func find(in index: TileIndex, x: Double, y: Double) -> Int? {
        let w = Double(1 << FowFormat.worldBitsLog2)
        guard x >= 0, y >= 0, x < w, y < w else { return nil }
        let tileBits = Double(FowFormat.tileWidth * 64)
        let tile = TileIndex.key(Int(x / tileBits), Int(y / tileBits))
        return index.tiles[tile]?.first { Self.contains(regions[$0], x: x, y: y) }
    }

    /// 偶奇規則（輪をまたいで数える）で、点が地域の内側か。
    static func contains(_ region: Region, x: Double, y: Double) -> Bool {
        guard region.bounds.contains(x: x, y: y) else { return false }
        var inside = false
        for ring in region.rings where ring.bounds.minY <= y && y < ring.bounds.maxY && x < ring.bounds.maxX {
            if ring.crossingsToRight(x: x, y: y) % 2 == 1 { inside.toggle() }
        }
        return inside
    }

    // MARK: - 地図用

    /// 地域の輪郭（MapKit の座標）。
    func outline(of index: Int) -> MKMultiPolyline {
        let k = MKMapSize.world.width / Double(1 << FowFormat.worldBitsLog2)
        let lines = regions[index].rings.map { ring -> MKPolyline in
            var points = zip(ring.xs, ring.ys).map { MKMapPoint(x: $0 * k, y: $1 * k) }
            if let first = points.first { points.append(first) }
            return MKPolyline(points: points, count: points.count)
        }
        return MKMultiPolyline(lines)
    }
}

/// 世界座標（ビット単位）の長方形。
struct BitRect: Equatable {
    var minX, minY, maxX, maxY: Double

    static let null = BitRect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    var isNull: Bool { minX > maxX }
    var midX: Double { (minX + maxX) / 2 }
    var midY: Double { (minY + maxY) / 2 }

    func union(_ o: BitRect) -> BitRect {
        BitRect(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    func intersects(_ o: BitRect) -> Bool {
        minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY
    }

    func contains(x: Double, y: Double) -> Bool {
        minX <= x && x <= maxX && minY <= y && y <= maxY
    }

    var mapRect: MKMapRect {
        let k = MKMapSize.world.width / Double(1 << FowFormat.worldBitsLog2)
        return MKMapRect(x: minX * k, y: minY * k, width: (maxX - minX) * k, height: (maxY - minY) * k)
    }
}

/// 境界の輪 1 つ。長い輪でも速く判定できるよう、辺を一定数ずつの塊に分けて塊ごとの範囲を持つ。
struct Ring {
    let xs: [Double]
    let ys: [Double]
    let bounds: BitRect
    private let chunks: [BitRect]
    static let chunkSize = 32

    init(xs: [Double], ys: [Double]) {
        self.xs = xs
        self.ys = ys
        var chunks: [BitRect] = []
        let n = xs.count
        var start = 0
        while start < n {
            let end = min(start + Self.chunkSize, n)
            var r = BitRect.null
            for i in start...end {  // 塊の最後の辺の終点（次の塊の始点、または輪の始点）まで含める
                let j = i % n
                r = r.union(BitRect(minX: xs[j], minY: ys[j], maxX: xs[j], maxY: ys[j]))
            }
            chunks.append(r)
            start = end
        }
        self.chunks = chunks
        bounds = chunks.reduce(BitRect.null) { $0.union($1) }
    }

    /// 点から右へ伸ばした半直線と交わる辺の数。
    func crossingsToRight(x: Double, y: Double) -> Int {
        let n = xs.count
        var count = 0
        for (c, r) in chunks.enumerated() where r.minY <= y && y < r.maxY && x < r.maxX {
            let start = c * Self.chunkSize
            for i in start..<min(start + Self.chunkSize, n) {
                let j = i + 1 == n ? 0 : i + 1
                let yi = ys[i], yj = ys[j]
                guard (yi > y) != (yj > y) else { continue }
                let cx = xs[i] + (y - yi) / (yj - yi) * (xs[j] - xs[i])
                if cx > x { count += 1 }
            }
        }
        return count
    }

    /// 輪の辺が長方形にかかっているかもしれないか（塊の範囲で大まかに見る）。
    func crosses(_ rect: BitRect) -> Bool {
        bounds.intersects(rect) && chunks.contains { $0.intersects(rect) }
    }
}

/// 霧のタイル（128×128 ブロック）ごとに、範囲が重なる地域を並べた索引。
private struct TileIndex {
    var tiles: [UInt32: [Int]] = [:]

    static func key(_ tx: Int, _ ty: Int) -> UInt32 { UInt32(tx) << 16 | UInt32(ty) }

    init(regions: [RegionCatalog.Region], members: [Int]) {
        let tileBits = Double(FowFormat.tileWidth * 64)
        let maxTile = FowFormat.mapWidth - 1
        for i in members {
            // 輪ごとに見る（離島を持つ国の外接長方形全体を登録しないように）
            var tiles = Set<UInt32>()
            for ring in regions[i].rings {
                let b = ring.bounds
                let tx0 = max(0, Int(b.minX / tileBits)), tx1 = min(maxTile, Int(b.maxX / tileBits))
                let ty0 = max(0, Int(b.minY / tileBits)), ty1 = min(maxTile, Int(b.maxY / tileBits))
                for tx in tx0...tx1 { for ty in ty0...ty1 { tiles.insert(Self.key(tx, ty)) } }
            }
            for t in tiles { self.tiles[t, default: []].append(i) }
        }
    }
}

/// regions.bin を先頭から読む。
private struct ByteReader {
    let data: Data
    var offset = 0

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard offset + n <= data.count else { throw RegionCatalog.ParseError.truncated }
        defer { offset += n }
        return [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + n])
    }

    private mutating func raw<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { throw RegionCatalog.ParseError.truncated }
        defer { offset += size }
        return T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    mutating func u8() throws -> UInt8 { try raw(UInt8.self) }
    mutating func u32() throws -> UInt32 { try raw(UInt32.self) }
    mutating func i32() throws -> Int32 { try raw(Int32.self) }
    mutating func f64() throws -> Double { Double(bitPattern: try raw(UInt64.self)) }
    mutating func string() throws -> String {
        let n = Int(try raw(UInt16.self))
        return String(decoding: try bytes(n), as: UTF8.self)
    }
}
