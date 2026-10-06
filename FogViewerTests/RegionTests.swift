import XCTest
@testable import FogViewer

final class RingTests: XCTestCase {
    /// 0〜10 の正方形に 4〜6 の穴。偶奇規則で穴の中は外になる。
    func testSquareWithHole() {
        let outer = Ring(xs: [0, 10, 10, 0], ys: [0, 0, 10, 10])
        let hole = Ring(xs: [4, 6, 6, 4], ys: [4, 4, 6, 6])
        let region = RegionCatalog.Region(level: .country, parent: nil, code: "X", name: "X", group: "", flag: "", areaKm2: 0,
                                          rings: [outer, hole], bounds: outer.bounds)
        XCTAssertTrue(RegionCatalog.contains(region, x: 1, y: 1))
        XCTAssertTrue(RegionCatalog.contains(region, x: 9.5, y: 5))
        XCTAssertFalse(RegionCatalog.contains(region, x: 5, y: 5))
        XCTAssertFalse(RegionCatalog.contains(region, x: 11, y: 5))
        XCTAssertFalse(RegionCatalog.contains(region, x: -1, y: 5))
    }

    /// 塊（32 辺）をまたぐ長い輪でも数え漏れがない。
    func testLongRingAcrossChunks() {
        let n = 1000
        let xs = (0..<n).map { cos(Double($0) / Double(n) * 2 * .pi) * 100 }
        let ys = (0..<n).map { sin(Double($0) / Double(n) * 2 * .pi) * 100 }
        let ring = Ring(xs: xs, ys: ys)
        for (x, y, inside) in [(0.0, 0.0, true), (99.0, 0.5, true), (0.3, -99.0, true), (101.0, 0, false), (70.0, 72.0, false)] {
            XCTAssertEqual(ring.crossingsToRight(x: x, y: y) % 2 == 1, inside, "(\(x), \(y))")
        }
        XCTAssertTrue(ring.crosses(BitRect(minX: 95, minY: -5, maxX: 105, maxY: 5)))
        XCTAssertFalse(ring.crosses(BitRect(minX: -5, minY: -5, maxX: 5, maxY: 5)))
    }
}

final class RegionCatalogTests: XCTestCase {
    private static let catalog: RegionCatalog? = RegionCatalog.bundled.flatMap { try? RegionCatalog.load(url: $0) }

    private func catalog() throws -> RegionCatalog { try XCTUnwrap(Self.catalog, "regions.bin が読めません") }

    /// 経度・緯度の地点に 1 ビットだけ立てて、どの地域に入るかを名前（親から順に）で返す。
    private func place(_ c: RegionCatalog, lon: Double, lat: Double) -> [String]? {
        let p = RegionCatalog.bitPoint(lon: lon, lat: lat)
        let x = Int(p.x), y = Int(p.y)
        var bitmap = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)
        bitmap[(y % 64) * 8 + (x % 64) / 8] |= 0x80 >> UInt8(x % 8)
        let result = c.classify(blockX: x / 64, blockY: y / 64, bitmap: bitmap)
        XCTAssertEqual(result.values.reduce(0, +), 1)
        guard let region = result.keys.first, var i = region else { return nil }
        var names = [c.regions[i].name]
        while let p = c.regions[i].parent { names.insert(c.regions[p].name, at: 0); i = p }
        return names
    }

    func testKnownPlaces() throws {
        let c = try catalog()
        XCTAssertEqual(place(c, lon: 139.7671, lat: 35.6812), ["アジア", "日本", "東京都", "千代田区"])     // 東京駅
        XCTAssertEqual(place(c, lon: 141.3508, lat: 43.0687), ["アジア", "日本", "北海道", "札幌市", "北区"])  // 札幌駅
        XCTAssertEqual(place(c, lon: 135.4959, lat: 34.7025), ["アジア", "日本", "大阪府", "大阪市", "北区"])  // 大阪駅
        XCTAssertEqual(place(c, lon: 127.6809, lat: 26.2124), ["アジア", "日本", "沖縄県", "那覇市"])
        XCTAssertEqual(place(c, lon: 2.2945, lat: 48.8584), ["ヨーロッパ", "フランス"])            // エッフェル塔
        XCTAssertEqual(place(c, lon: -122.4194, lat: 37.7749)?.first, "北アメリカ")
        XCTAssertNil(place(c, lon: 150, lat: 30))                                                 // 太平洋
    }

    func testMunicipalityCounts() throws {
        let c = try catalog()
        let japan = try XCTUnwrap(c.regions.firstIndex { $0.code == "JPN" })
        XCTAssertEqual(c.children[japan].count, 47)
        XCTAssertEqual(c.regions[japan].flag, "JP")
        XCTAssertEqual(c.regions[japan].group, "東アジア")
        XCTAssertEqual(c.regions[c.children[japan][0]].group, "北海道")
        let p = RegionCatalog.bitPoint(lon: 139.77, lat: 35.68)
        XCTAssertEqual(c.country(atX: p.x, y: p.y), japan)
        XCTAssertGreaterThan(c.municipalityCounts[japan], 1850)
        let tokyo = try XCTUnwrap(c.children[japan].first { c.regions[$0].name == "東京都" })
        XCTAssertTrue(c.children[tokyo].contains { c.regions[$0].name == "新宿区" })
    }

    /// 縮図のマスが、大きな地域の真ん中で正しい地域になる（世界ならオーストラリア、日本なら北海道）。
    func testPixelMap() throws {
        let c = try catalog()
        let stats = RegionStats.compute(fog: .empty, catalog: c)
        let japan = try XCTUnwrap(c.regions.firstIndex { $0.code == "JPN" })
        let australia = try XCTUnwrap(c.regions.firstIndex { $0.code == "AUS" })
        let hokkaido = try XCTUnwrap(c.children[japan].first { c.regions[$0].name == "北海道" })
        let cases: [(parent: Int?, lon: Double, lat: Double, expected: Int)] = [
            (nil, 134, -25, australia), (japan, 143, 43.5, hokkaido),
        ]
        for t in cases {
            let map = PixelMap.build(parent: t.parent, catalog: c, stats: stats, fog: .empty)
            let p = RegionCatalog.bitPoint(lon: t.lon, lat: t.lat)
            let side = (map.frame.maxX - map.frame.minX) / Double(map.cols)
            let col = Int((p.x - map.frame.minX) / side), row = Int((p.y - map.frame.minY) / side)
            XCTAssertEqual(map.value(col: col, row: row), Int32(t.expected), "parent \(String(describing: t.parent))")
        }
    }

    /// 都道府県のページで、市区町村に入らない海岸沿いのすき間を隣の陸として塗らない。内陸には海の穴をあけない。
    func testPixelMapCoastAndInland() throws {
        let c = try catalog()
        let stats = RegionStats.compute(fog: .empty, catalog: c)
        let japan = try XCTUnwrap(c.regions.firstIndex { $0.code == "JPN" })
        let hokkaido = try XCTUnwrap(c.children[japan].first { c.regions[$0].name == "北海道" })
        let saitama = try XCTUnwrap(c.children[japan].first { c.regions[$0].name == "埼玉県" })

        // 北緯 42 度より北で「範囲の外の陸」になるのは外国（千島など）だけ。日本の海岸沿いのすき間は海
        let map = PixelMap.build(parent: hokkaido, catalog: c, stats: stats, fog: .empty)
        let side = max(map.frame.maxX - map.frame.minX, map.frame.maxY - map.frame.minY) / Double(PixelMap.resolution)
        let north = RegionCatalog.bitPoint(lon: 141, lat: 42).y
        for row in 0..<map.rows where map.frame.minY + (Double(row) + 1) * side < north {
            for col in 0..<map.cols where map.value(col: col, row: row) == PixelMap.otherLand {
                let x = map.frame.minX + (Double(col) + 0.5) * side, y = map.frame.minY + (Double(row) + 0.5) * side
                let country = c.country(atX: x, y: y)
                XCTAssertTrue(country != nil && country != japan, "row \(row) col \(col)")
            }
        }
        // 埼玉県のまわりは陸だけ
        let inland = PixelMap.build(parent: saitama, catalog: c, stats: stats, fog: .empty)
        XCTAssertFalse(inland.cells.contains(PixelMap.sea))
    }

    /// 経度 ±180 にかかる国でも縮図を作れる（範囲が世界の外に出ると落ちていた）。
    func testPixelMapAcrossDateLine() throws {
        let c = try catalog()
        let antarctica = try XCTUnwrap(c.regions.firstIndex { $0.code == "ATA" })
        let russia = try XCTUnwrap(c.regions.firstIndex { $0.code == "RUS" })
        // チュコトカ（経度 -173）に 1 ビットだけ晴れたブロック
        let p = RegionCatalog.bitPoint(lon: -173, lat: 65.5)
        let x = Int(p.x), y = Int(p.y)
        var bitmap = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)
        bitmap[(y % 64) * 8 + (x % 64) / 8] |= 0x80 >> UInt8(x % 8)
        let fog = FogData(blocks: [FogData.blockKey(x / 64, y / 64): FogBlock(bitmap: bitmap)])
        let stats = RegionStats.compute(fog: fog, catalog: c)
        for parent in [antarctica, russia] {
            let map = PixelMap.build(parent: parent, catalog: c, stats: stats, fog: fog)
            XCTAssertGreaterThanOrEqual(map.frame.minX, 0)
            XCTAssertTrue(map.cells.contains(Int32(parent)), c.regions[parent].name)
        }
    }

    /// 実データで全体を判定する時間と、面積の合計が霧全体の面積と一致すること。
    func testRealFogIfPresent() throws {
        let c = try catalog()
        let folder = FogStore.syncFolder
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path), "iCloud データなし")
        let fog = FogParser.load(syncFolder: folder).data
        let t = Date()
        let stats = RegionStats.compute(fog: fog, catalog: c)
        print("BENCH regions: \(Int(Date().timeIntervalSince(t) * 1000)) ms, blocks \(fog.blocks.count)")
        XCTAssertEqual(stats.totalAreaKm2, fog.exploredAreaKm2, accuracy: 1e-6 * max(1, fog.exploredAreaKm2))
        let assigned = c.regions.indices.filter { c.regions[$0].parent == nil }.reduce(0) { $0 + stats.entry($1).areaKm2 }
        XCTAssertEqual(assigned + stats.unassigned.areaKm2, stats.totalAreaKm2, accuracy: 1e-6)
        for i in c.regions.indices where c.regions[i].parent == nil && stats.entry(i).bits > 0 {
            print("BENCH country \(c.regions[i].name): \(String(format: "%.2f", stats.entry(i).areaKm2)) km², 市区町村 \(stats.entry(i).visitedMunicipalities)")
        }
        print("BENCH unassigned: \(String(format: "%.3f", stats.unassigned.areaKm2)) km²")

        // 前回の判定を使い回しても同じ結果になる（1 ブロックだけ変えて、そのブロックだけ判定し直す）
        let (_, classified) = RegionStats.compute(fog: fog, catalog: c, reusing: [:])
        var blocks = fog.blocks
        let changed = try XCTUnwrap(blocks.keys.first)
        blocks[changed] = FogBlock(bitmap: [UInt8](repeating: 0xFF, count: FowFormat.blockBitmapSize))
        let edited = FogData(blocks: blocks)
        let t2 = Date()
        let warm = RegionStats.compute(fog: edited, catalog: c, reusing: classified).stats
        print("BENCH regions (reused): \(Int(Date().timeIntervalSince(t2) * 1000)) ms")
        let cold = RegionStats.compute(fog: edited, catalog: c)
        XCTAssertEqual(warm.entries.map(\.bits), cold.entries.map(\.bits))
        XCTAssertEqual(warm.unassigned.bits, cold.unassigned.bits)
        XCTAssertEqual(warm.totalAreaKm2, cold.totalAreaKm2, accuracy: 1e-9 * max(1, cold.totalAreaKm2))
    }
}
