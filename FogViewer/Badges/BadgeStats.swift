import Foundation

/// バッジ 1 つ分の判定結果。今の霧だけから決まり、いつ取れたかは持たない。
struct Badge: Identifiable {
    enum Category: Int, CaseIterable, Identifiable {
        case mesh, confluence, cape, prefectureMesh
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .mesh: "メッシュ"
            case .prefectureMesh: "都道府県の 1km メッシュ"
            case .confluence: "緯度経度の交点"
            case .cape: "日本の端"
            }
        }
    }

    /// 段階。しきい値以上なら届いている。
    struct Tier {
        let threshold: Double
        let name: String
    }

    let id: String
    let category: Category
    let title: String
    let symbol: String
    let value: Double
    /// 値の単位（「マス」「%」「個」）。
    let unit: String
    let tiers: [Tier]
    /// カードの下に添える一言（全体の数や、いちばん近い目標まで）。
    let detail: String?
    let target: Target?

    /// 地図で見せるもの。
    enum Target {
        case region(Int)
        case points([Point])
    }

    struct Point {
        let name: String
        let lat: Double
        let lon: Double
        let reached: Bool
    }

    /// 届いた段階の数（0 = まだ）。
    var level: Int { tiers.filter { value >= $0.threshold }.count }
    var next: Tier? { tiers.first { value < $0.threshold } }

    static func tiers(_ thresholds: Double...) -> [Tier] {
        zip(thresholds, ["銅", "銀", "金"]).map { Tier(threshold: $0, name: $1) }
    }
}

// MARK: - 標準地域メッシュ（JIS X 0410）

/// 3 次メッシュ（緯度 30 秒 × 経度 45 秒、約 1 km 四方）の行と列。
/// 行は緯度 × 120、列は（経度 − 100）× 80 の整数部。1 次・2 次メッシュはこれを 80・10 で割ったもの。
struct MeshCell: Hashable {
    let row: Int
    let col: Int

    init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    init(lat: Double, lon: Double) {
        row = Int((lat * 120).rounded(.down))
        col = Int(((lon - 100) * 80).rounded(.down))
    }

    /// 2 次メッシュ（約 10 km 四方）。
    var secondary: MeshCell { MeshCell(row: row / 10, col: col / 10) }

    var center: (lat: Double, lon: Double) { ((Double(row) + 0.5) / 120, (Double(col) + 0.5) / 80 + 100) }

    /// 8 桁のメッシュコード（例：東京駅は 53394611）。
    var code: String {
        "\(row / 80)\(col / 80)\(row % 80 / 10)\(col % 80 / 10)\(row % 10)\(col % 10)"
    }
}

// MARK: - 霧によらない下ごしらえ

/// 霧によらず境界データだけで決まるもの。最初に一度だけ作る。
struct BadgeGeography {
    /// 日本の陸の 3 次メッシュ（中心が日本の陸にあるもの）と、その都道府県（市区町村に入らない海岸沿いは nil）。
    let landMeshes: [MeshCell: Int?]
    /// 都道府県ごとの陸の 3 次メッシュの数。
    let prefectureMeshCounts: [Int: Int]
    /// 陸の 3 次メッシュを 1 つでも含む 2 次メッシュの数。
    let landSecondaryCount: Int
    /// 陸にある緯度経度の交点（世界）。
    let confluences: [Confluence]

    struct Confluence {
        let lat: Int
        let lon: Int
        let inJapan: Bool
        /// 交点のある国、日本なら都道府県と市区町村。
        let place: String

        var name: String {
            "\(lat >= 0 ? "北緯" : "南緯")\(abs(lat))度 \(lon >= 0 ? "東経" : "西経")\(abs(lon))度"
        }
    }

    static func build(catalog: RegionCatalog) -> BadgeGeography {
        let japan = catalog.regions.firstIndex { $0.level == .country && $0.flag == "JP" }
        func prefecture(of index: Int) -> Int? {
            var i: Int? = index
            while let j = i, catalog.regions[j].level != .prefecture { i = catalog.regions[j].parent }
            return i
        }
        func isJapan(x: Double, y: Double) -> Bool { japan != nil && catalog.country(atX: x, y: y) == japan }

        // 市区町村の範囲にかかるメッシュだけ調べる（日本を囲む四角全体を調べると、ほとんど海で 8 倍かかる）
        var land: [MeshCell: Int?] = [:]
        var seen = Set<MeshCell>()
        for region in catalog.regions where region.level == .municipality {
            let b = region.bounds
            let south = MeshCell(lat: FogData.latitude(ofBitY: b.maxY), lon: FogData.longitude(ofBitX: b.minX))
            let north = MeshCell(lat: FogData.latitude(ofBitY: b.minY), lon: FogData.longitude(ofBitX: b.maxX))
            for row in south.row...north.row {
                for col in south.col...north.col {
                    let cell = MeshCell(row: row, col: col)
                    guard seen.insert(cell).inserted else { continue }
                    let c = cell.center
                    let p = RegionCatalog.bitPoint(lon: c.lon, lat: c.lat)
                    if let m = catalog.municipality(atX: p.x, y: p.y) {
                        land[cell] = prefecture(of: m)
                    } else if isJapan(x: p.x, y: p.y) {
                        land[cell] = .some(nil)
                    }
                }
            }
        }
        var counts: [Int: Int] = [:]
        for case let pref? in land.values { counts[pref, default: 0] += 1 }
        let secondary = Set(land.keys.map(\.secondary)).count

        var confluences: [Confluence] = []
        for lat in -80...80 {
            for lon in -180..<180 {
                let p = RegionCatalog.bitPoint(lon: Double(lon), lat: Double(lat))
                if let m = catalog.municipality(atX: p.x, y: p.y) {
                    let pref = prefecture(of: m).map { catalog.regions[$0].name } ?? ""
                    confluences.append(Confluence(lat: lat, lon: lon, inJapan: true, place: pref + catalog.regions[m].name))
                } else if let country = catalog.country(atX: p.x, y: p.y) {
                    confluences.append(Confluence(lat: lat, lon: lon, inJapan: country == japan,
                                                  place: catalog.regions[country].name))
                }
            }
        }
        return BadgeGeography(landMeshes: land, prefectureMeshCounts: counts, landSecondaryCount: secondary,
                              confluences: confluences)
    }
}

// MARK: - 判定

enum BadgeStats {
    /// 「行った」とみなす、交点からの距離（Degree Confluence Project と同じ）。
    static let confluenceRadiusM = 100.0
    /// 「行った」とみなす、岬からの距離。
    static let capeRadiusM = 300.0

    /// 本土 4 島の東西南北の端。
    static let capes: [(name: String, lat: Double, lon: Double)] = [
        ("宗谷岬", 45.5228, 141.9364),
        ("納沙布岬", 43.3853, 145.8172),
        ("佐多岬", 30.9944, 130.6619),
        ("神崎鼻", 33.2142, 129.5542),
    ]

    static func compute(fog: FogData, catalog: RegionCatalog, geography: BadgeGeography) -> [Badge] {
        meshBadges(fog: fog, catalog: catalog, geography: geography)
            + [confluenceBadge(fog: fog, geography: geography), capeBadge(fog: fog)]
    }

    // MARK: メッシュ

    static func meshBadges(fog: FogData, catalog: RegionCatalog, geography: BadgeGeography) -> [Badge] {
        // 足跡のある 3 次メッシュのうち、陸のもの（分母と同じく、中心が陸にあるもの）
        var visited = Set<MeshCell>()
        for (key, block) in fog.blocks {
            let bx = Int(key >> 16), by = Int(key & 0xFFFF)
            block.forEachVisited { x, y in
                let lat = FogData.latitude(ofBitY: Double(by * 64 + y) + 0.5)
                let lon = FogData.longitude(ofBitX: Double(bx * 64 + x) + 0.5)
                guard lat > 20, lat < 46.5, lon > 122, lon < 154 else { return }
                visited.insert(MeshCell(lat: lat, lon: lon))
            }
        }
        let land = visited.filter { geography.landMeshes[$0] != nil }
        var byPrefecture: [Int: Int] = [:]
        for cell in land { if case let pref?? = geography.landMeshes[cell] { byPrefecture[pref, default: 0] += 1 } }
        let total = geography.landMeshes.count
        let secondary = Set(land.map(\.secondary)).count

        var badges = [
            Badge(id: "mesh.1km", category: .mesh, title: "1km メッシュ", symbol: "square.grid.3x3.fill",
                  value: Double(land.count), unit: "マス", tiers: Badge.tiers(1000, 5000, 20000),
                  detail: "日本の陸地 \(Passport.number(Double(total), fraction: 0)) マスのうち "
                      + Passport.number(Double(land.count) / Double(max(total, 1)) * 100, fraction: 2) + "%",
                  target: nil),
            Badge(id: "mesh.10km", category: .mesh, title: "10km メッシュ", symbol: "square.grid.2x2.fill",
                  value: Double(secondary), unit: "マス", tiers: Badge.tiers(100, 1000, 3000),
                  detail: "日本の陸地 \(Passport.number(Double(geography.landSecondaryCount), fraction: 0)) マスのうち",
                  target: nil),
        ]
        for (pref, count) in byPrefecture.sorted(by: { $0.key < $1.key }) {
            let all = geography.prefectureMeshCounts[pref] ?? 0
            guard all > 0 else { continue }
            let name = catalog.regions[pref].name
            badges.append(Badge(id: "mesh.pref.\(catalog.regions[pref].code)", category: .prefectureMesh,
                                title: name, symbol: "square.grid.3x3.topleft.filled",
                                value: Double(count) / Double(all) * 100, unit: "%", tiers: Badge.tiers(10, 25, 50),
                                detail: "\(Passport.number(Double(count), fraction: 0)) / \(Passport.number(Double(all), fraction: 0)) マス",
                                target: .region(pref)))
        }
        return badges
    }

    // MARK: 交点

    static func confluenceBadge(fog: FogData, geography: BadgeGeography) -> Badge {
        let reached = geography.confluences.filter {
            fog.hasVisited(lat: Double($0.lat), lon: Double($0.lon), withinMeters: confluenceRadiusM)
        }
        let japan = geography.confluences.filter(\.inJapan)
        let japanReached = reached.filter(\.inJapan).count
        // まだ行っていない日本の交点のうち、足跡からいちばん近いもの
        let nearest = japan
            .filter { c in !reached.contains { $0.lat == c.lat && $0.lon == c.lon } }
            .compactMap { c in fog.nearestVisitedKm(lat: Double(c.lat), lon: Double(c.lon)).map { (c, $0) } }
            .sorted { $0.1 < $1.1 }
        var detail = "日本 \(japanReached) / \(japan.count)"
        if let (c, km) = nearest.first {
            detail += "・\(c.name)（\(c.place)）まであと \(Passport.number(km, fraction: 1)) km"
        }
        let points = reached.map { Badge.Point(name: $0.name, lat: Double($0.lat), lon: Double($0.lon), reached: true) }
            + nearest.prefix(3).map { Badge.Point(name: $0.0.name, lat: Double($0.0.lat), lon: Double($0.0.lon), reached: false) }
        return Badge(id: "confluence", category: .confluence, title: "緯度経度の交点", symbol: "plus.viewfinder",
                     value: Double(reached.count), unit: "個", tiers: Badge.tiers(1, 5, 10),
                     detail: detail, target: points.isEmpty ? nil : .points(points))
    }

    // MARK: 岬

    static func capeBadge(fog: FogData) -> Badge {
        let results = capes.map { cape in
            (cape, fog.hasVisited(lat: cape.lat, lon: cape.lon, withinMeters: capeRadiusM),
             fog.nearestVisitedKm(lat: cape.lat, lon: cape.lon))
        }
        let reached = results.filter(\.1).count
        let nearest = results.filter { !$0.1 }.compactMap { r in r.2.map { (r.0.name, $0) } }.min { $0.1 < $1.1 }
        let detail = nearest.map { "\($0.0)まであと \(Passport.number($0.1, fraction: 0)) km" } ?? "4 つの岬すべてに到達"
        return Badge(id: "cape", category: .cape, title: "東西南北の端", symbol: "safari.fill",
                     value: Double(reached), unit: "か所", tiers: Badge.tiers(1, 2, 4), detail: detail,
                     target: .points(results.map { Badge.Point(name: $0.0.name, lat: $0.0.lat, lon: $0.0.lon, reached: $0.1) }))
    }
}

// MARK: - 霧への問い合わせ

extension FogData {
    static func latitude(ofBitY y: Double) -> Double {
        latitude(ofBlockY: y / Double(FowFormat.bitmapWidth))
    }

    static func longitude(ofBitX x: Double) -> Double {
        x / Double(1 << FowFormat.worldBitsLog2) * 360 - 180
    }

    /// その緯度での 1 ビットの長さ（m）。
    static func bitMeters(atLatitude lat: Double) -> Double {
        40_075_016.686 / Double(1 << FowFormat.worldBitsLog2) * cos(lat * .pi / 180)
    }

    func isVisited(bitX x: Int, y: Int) -> Bool {
        block(x >> 6, y >> 6)?.isVisited(x & 63, y & 63) ?? false
    }

    /// 地点から指定の距離以内に晴れたビットがあるか。
    func hasVisited(lat: Double, lon: Double, withinMeters meters: Double) -> Bool {
        let p = RegionCatalog.bitPoint(lon: lon, lat: lat)
        let x = Int(p.x), y = Int(p.y)
        let r = Int((meters / Self.bitMeters(atLatitude: lat)).rounded())
        let world = 1 << FowFormat.worldBitsLog2
        // 世界の端（経度 ±180 など）では範囲を切り詰める
        let x0 = max(x - r, 0), x1 = min(x + r, world - 1), y0 = max(y - r, 0), y1 = min(y + r, world - 1)
        guard x0 <= x1, y0 <= y1 else { return false }
        var any = false
        for by in (y0 >> 6)...(y1 >> 6) { for bx in (x0 >> 6)...(x1 >> 6) where block(bx, by) != nil { any = true } }
        guard any else { return false }
        for yy in y0...y1 {
            for xx in x0...x1 where (xx - x) * (xx - x) + (yy - y) * (yy - y) <= r * r {
                if isVisited(bitX: xx, y: yy) { return true }
            }
        }
        return false
    }

    /// 地点からいちばん近い晴れたビットまでの距離（km）。霧が空なら nil。
    func nearestVisitedKm(lat: Double, lon: Double) -> Double? {
        // ブロックの中心で近いものを選び、その周りのブロックだけビットまで見る
        let blockKm = Self.bitMeters(atLatitude: lat) * 64 / 1000
        let candidates = blockCoords.map { c -> (x: Int, y: Int, km: Double) in
            let clat = Self.latitude(ofBlockY: Double(c.y) + 0.5)
            let clon = Self.longitude(ofBitX: (Double(c.x) + 0.5) * 64)
            return (c.x, c.y, Self.distanceKm(lat, lon, clat, clon))
        }
        guard let best = candidates.min(by: { $0.km < $1.km }) else { return nil }
        var nearest = Double.infinity
        for c in candidates where c.km <= best.km + blockKm * 1.5 {
            block(c.x, c.y)?.forEachVisited { x, y in
                let blat = Self.latitude(ofBitY: Double(c.y * 64 + y) + 0.5)
                let blon = Self.longitude(ofBitX: Double(c.x * 64 + x) + 0.5)
                nearest = min(nearest, Self.distanceKm(lat, lon, blat, blon))
            }
        }
        return nearest
    }

    /// 2 点間の大円距離（km）。
    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 6371.0088 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
