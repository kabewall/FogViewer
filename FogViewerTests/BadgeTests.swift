import XCTest
@testable import FogViewer

final class MeshCellTests: XCTestCase {
    /// 東京駅（北緯 35.6812 度、東経 139.7671 度）の 3 次メッシュ。
    /// 緯度 × 120 = 4281.7 → 行 4281、（経度 − 100）× 80 = 3181.4 → 列 3181。
    /// 1 次 4281/80 = 53, 3181/80 = 39、2 次 41/10 = 4, 61/10 = 6、3 次 1, 1 → 5339-46-11。
    func testMeshCode() {
        let cell = MeshCell(lat: 35.6812, lon: 139.7671)
        XCTAssertEqual(cell.row, 4281)
        XCTAssertEqual(cell.col, 3181)
        XCTAssertEqual(cell.code, "53394611")
        XCTAssertEqual(cell.secondary, MeshCell(row: 428, col: 318))
        // 中心は同じメッシュに入る
        let c = cell.center
        XCTAssertEqual(MeshCell(lat: c.lat, lon: c.lon), cell)
    }
}

final class BadgeTierTests: XCTestCase {
    private func badge(_ value: Double) -> Badge {
        Badge(id: "t", category: .mesh, title: "t", symbol: "circle", value: value, unit: "マス",
              tiers: Badge.tiers(1000, 5000, 20000), detail: nil, target: nil)
    }

    func testLevelsAndProgress() {
        XCTAssertEqual(badge(0).level, 0)
        XCTAssertEqual(badge(999).level, 0)
        XCTAssertEqual(badge(1000).level, 1)
        XCTAssertEqual(badge(3000).next?.name, "銀")
        XCTAssertEqual(BadgeListView.progress(badge(3000)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(badge(20000).level, 3)
        XCTAssertNil(badge(20000).next)
        XCTAssertEqual(BadgeListView.progress(badge(25000)), 1)
    }
}

final class FogQueryTests: XCTestCase {
    /// 地点から東へ `meters` だけ離れたビット 1 つだけが晴れた霧。
    private func fog(lat: Double, lon: Double, eastMeters meters: Double) -> FogData {
        let p = RegionCatalog.bitPoint(lon: lon, lat: lat)
        let x = Int(p.x + meters / FogData.bitMeters(atLatitude: lat)), y = Int(p.y)
        var bitmap = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)
        bitmap[(y % 64) * 8 + (x % 64) / 8] |= 0x80 >> UInt8(x % 8)
        return FogData(blocks: [FogData.blockKey(x / 64, y / 64): FogBlock(bitmap: bitmap)])
    }

    func testHasVisitedAndNearest() throws {
        let f = fog(lat: 35, lon: 136, eastMeters: 60)
        XCTAssertTrue(f.hasVisited(lat: 35, lon: 136, withinMeters: 100))
        XCTAssertFalse(f.hasVisited(lat: 35, lon: 136, withinMeters: 30))
        let km = try XCTUnwrap(f.nearestVisitedKm(lat: 35, lon: 136))
        XCTAssertEqual(km, 0.06, accuracy: 0.015)
        XCTAssertNil(FogData.empty.nearestVisitedKm(lat: 35, lon: 136))
    }

    /// 経度 −180 の地点でも範囲外を引かずに判定できる。
    func testHasVisitedAtWorldEdge() {
        XCTAssertFalse(FogData.empty.hasVisited(lat: 65, lon: -180, withinMeters: 100))
        XCTAssertFalse(fog(lat: 65, lon: -179.99, eastMeters: 0).hasVisited(lat: 65, lon: 179.999, withinMeters: 100))
    }

    func testDistance() {
        // 東京駅から大阪駅まで約 403 km
        XCTAssertEqual(FogData.distanceKm(35.6812, 139.7671, 34.7025, 135.4959), 403, accuracy: 3)
    }

    func testCapeBadge() {
        let soya = BadgeStats.capes[0]
        let badge = BadgeStats.capeBadge(fog: fog(lat: soya.lat, lon: soya.lon, eastMeters: 100))
        XCTAssertEqual(badge.value, 1)
        XCTAssertEqual(badge.level, 1)
        // 残りの岬のうち、いちばん近いもの（宗谷岬からは納沙布岬）までの距離を添える
        XCTAssertEqual(badge.detail?.hasPrefix("納沙布岬まであと"), true)
    }
}

final class BadgeGeographyTests: XCTestCase {
    /// 実際の境界で下ごしらえを作る。数と時間を確かめる。
    func testBuild() throws {
        let catalog = try RegionCatalog.shared.get()
        let start = Date()
        let g = BadgeGeography.build(catalog: catalog)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "BadgeGeography.build: %.1f 秒、陸の 3 次メッシュ %d、2 次メッシュ %d、交点 %d（日本 %d）",
                     elapsed, g.landMeshes.count, g.landSecondaryCount, g.confluences.count,
                     g.confluences.filter(\.inJapan).count))
        // 日本の陸地は約 37.8 万 km² なので、3 次メッシュ（約 0.85 km²）は 40 万前後
        XCTAssertGreaterThan(g.landMeshes.count, 350_000)
        XCTAssertLessThan(g.landMeshes.count, 450_000)
        let japan = try XCTUnwrap(catalog.regions.firstIndex { $0.code == "JPN" })
        let tokyo = try XCTUnwrap(catalog.children[japan].first { catalog.regions[$0].name == "東京都" })
        // 東京都は約 2,190 km²
        XCTAssertEqual(Double(g.prefectureMeshCounts[tokyo] ?? 0), 2100, accuracy: 300)
        XCTAssertEqual(g.prefectureMeshCounts.count, 47)
        // 日本の陸地にある交点（北緯 35 度・東経 139 度は伊豆半島）
        XCTAssertTrue(g.confluences.contains { $0.lat == 35 && $0.lon == 139 && $0.inJapan })
        XCTAssertGreaterThan(g.confluences.filter(\.inJapan).count, 30)
    }
}
