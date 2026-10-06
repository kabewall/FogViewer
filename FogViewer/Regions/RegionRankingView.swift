import SwiftUI

/// 地域ランキングの並べ方。
enum RegionSort: String, CaseIterable, Identifiable {
    case area, rate, code
    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "探索面積"
        case .rate: "探索率"
        case .code: "コード順"
        }
    }
}

/// 世界の霧のパスポートにならった地域ごとの探索の様子。
/// 世界 → 大陸 → 国 → 都道府県 → （政令指定都市 →）市区町村 の順にたどる。
struct RegionRankingView: View {
    @ObservedObject var model: RegionModel
    @ObservedObject var map: MapController
    @EnvironmentObject private var store: FogStore

    /// たどってきた地域。地図の輪郭と食い違わないよう、閉じても残るモデルの側に持つ。
    private var path: [Int] {
        get { model.path }
        nonmutating set { model.path = newValue }
    }

    var body: some View {
        if let catalog = model.catalog, let stats = model.stats {
            VStack(spacing: 0) {
                header(catalog)
                Divider()
                PassportPage(parent: path.last, catalog: catalog, stats: stats, model: model,
                             open: { path.append($0) })
                    .id(path.last)
            }
            // 階層を移ったら、その地域の輪郭を出す（世界に戻ったら消す）
            .onChange(of: path) { model.select(path.last, map: map) }
        } else if let message = model.errorMessage ?? (store.generation == 0 ? store.errorMessage : nil) {
            ContentUnavailableView("集計できません", systemImage: "exclamationmark.triangle", description: Text(message))
        } else if store.generation == 0 {
            ProgressView("記録を読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("地域ごとに集計中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 戻るボタンと、たどってきた道筋。
    private func header(_ catalog: RegionCatalog) -> some View {
        HStack(spacing: 6) {
            Button { path.removeLast() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(path.isEmpty)
                .help("ひとつ上の階層へ戻る")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    crumb("世界", depth: 0)
                    ForEach(Array(path.enumerated()), id: \.offset) { i, index in
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        crumb(catalog.regions[index].name, depth: i + 1)
                    }
                }
            }
            if model.isComputing {
                ProgressView().controlSize(.small).help("新しい記録で集計し直しています")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func crumb(_ title: String, depth: Int) -> some View {
        Button(title) { path.removeLast(path.count - depth) }
            .buttonStyle(.plain)
            .foregroundStyle(depth == path.count ? .primary : .secondary)
            .fontWeight(depth == path.count ? .semibold : .regular)
    }
}

// MARK: - 1 階層分のページ

private struct PassportPage: View {
    let parent: Int?
    let catalog: RegionCatalog
    let stats: RegionStats
    @ObservedObject var model: RegionModel
    let open: (Int) -> Void
    @AppStorage("regionSort") private var sort: RegionSort = .area
    @AppStorage("regionShowUnvisited") private var showUnvisited = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PassportCard(parent: parent, catalog: catalog, stats: stats)
                if let pixels = model.pixelMap(for: parent) {
                    PixelMapView(pixels: pixels, parent: parent, catalog: catalog, stats: stats,
                                 territory: territory, open: open)
                }
                if parent == nil { visitedFlags }
                if !groups.isEmpty { groupGauges }
                if !children.isEmpty { ranking }
                if parent == nil {
                    Text("境界：Natural Earth、「国土数値情報（行政区域データ）」（国土交通省）を加工して作成")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    // MARK: 数え方

    /// このページで並べる地域（世界なら大陸、日本なら都道府県…）。
    private var children: [Int] {
        guard let parent else { return catalog.regions.indices.filter { catalog.regions[$0].level == .continent } }
        return catalog.children[parent]
    }

    /// 縮図の上に出す「行った数 / 全体」とその呼び名。
    private var territory: (visited: Int, total: Int, title: String)? {
        let members: [Int]
        let title: String
        if parent == nil || catalog.regions[parent!].level == .continent {
            members = catalog.regions.indices.filter {
                catalog.regions[$0].level == .country && (parent == nil || catalog.regions[$0].parent == parent)
            }
            title = "テリトリー"
        } else if !children.isEmpty {
            members = children
            title = Self.childrenTitle(catalog.regions[parent!].level)
        } else {
            return nil
        }
        return (members.filter { stats.entry($0).bits > 0 }.count, members.count, title)
    }

    static func childrenTitle(_ level: RegionCatalog.Level) -> String {
        switch level {
        case .continent: "テリトリー"
        case .country: "都道府県"
        case .prefecture: "市区町村"
        default: "区"
        }
    }

    /// 小地域・地方ごとのまとまり（世界なら大陸ごと）。
    private var groups: [(name: String, visited: Int, total: Int)] {
        if parent == nil {
            return children.map { c in
                let countries = catalog.children[c]
                return (catalog.regions[c].name, countries.filter { stats.entry($0).bits > 0 }.count, countries.count)
            }.filter { $0.total > 0 }
        }
        var order: [String] = []
        var counts: [String: (Int, Int)] = [:]
        for i in children where !catalog.regions[i].group.isEmpty {
            let g = catalog.regions[i].group
            if counts[g] == nil { order.append(g) }
            let c = counts[g, default: (0, 0)]
            counts[g] = (c.0 + (stats.entry(i).bits > 0 ? 1 : 0), c.1 + 1)
        }
        guard order.count > 1 else { return [] }
        return order.map { ($0, counts[$0]!.0, counts[$0]!.1) }
    }

    // MARK: 部品

    /// 世界のページ：行った国の国旗。
    @ViewBuilder
    private var visitedFlags: some View {
        let countries = catalog.regions.indices
            .filter { catalog.regions[$0].level == .country && stats.entry($0).bits > 0 }
            .sorted { stats.entry($0).areaKm2 > stats.entry($1).areaKm2 }
        if !countries.isEmpty {
            let shown = countries.prefix(11)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(Array(shown), id: \.self) { i in
                    Button { open(i) } label: {
                        Text(Self.flag(catalog.regions[i].flag) ?? "🏳️").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .help(catalog.regions[i].name)
                }
                if countries.count > shown.count {
                    Text("\(countries.count - shown.count)+")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 小地域・地方ごとの「行った数 / 全体」のゲージ。
    private var groupGauges: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .leading)],
                  alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.name) { g in
                HStack(alignment: .bottom, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Passport.mint.opacity(0.18))
                            Capsule().fill(Passport.mint)
                                .frame(height: geo.size.height * (g.total > 0 ? Double(g.visited) / Double(g.total) : 0))
                        }
                    }
                    .frame(width: 5, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(g.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(g.visited)").font(.title3.weight(.bold)).monospacedDigit()
                            Text("/\(g.total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: ランキング

    private var ranking: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ランキング").font(.headline)
                Spacer()
                Picker("並べ方", selection: $sort) {
                    ForEach(RegionSort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle("まだ行っていない地域も出す", isOn: $showUnvisited)
                .font(.callout)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element) { rank, index in
                    Button { open(index) } label: {
                        RankRow(rank: stats.entry(index).bits > 0 ? rank + 1 : nil, index: index,
                                catalog: catalog, stats: stats)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    /// 並べ替えた行。行っていない地域は、出すときも後ろにまとめる。
    private var rows: [Int] {
        let visited = children.filter { stats.entry($0).bits > 0 }
        let sorted: [Int]
        switch sort {
        case .area: sorted = visited.sorted { stats.entry($0).areaKm2 > stats.entry($1).areaKm2 }
        case .rate: sorted = visited.sorted { rate($0) > rate($1) }
        case .code: sorted = visited  // 境界データはコード順に並んでいる
        }
        guard showUnvisited else { return sorted }
        return sorted + children.filter { stats.entry($0).bits == 0 }
    }

    private func rate(_ index: Int) -> Double { stats.rate(index, catalog: catalog) }

    /// ISO 3166-1 alpha-2 から国旗の絵文字を作る。
    static func flag(_ code: String) -> String? {
        guard code.count == 2 else { return nil }
        let scalars = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// パスポート風の色と数の書き方。
enum Passport {
    static let green = Color(red: 0.13, green: 0.84, blue: 0.45)
    static let mint = Color(red: 0.37, green: 0.86, blue: 0.67)
    static let sea = Color(red: 0.05, green: 0.15, blue: 0.27)
    static let grid = Color.white.opacity(0.05)
    static let otherLand = Color(red: 0.13, green: 0.28, blue: 0.35)
    static let land = Color(red: 0.22, green: 0.50, blue: 0.47)
    static let dot = Color(red: 0.98, green: 0.88, blue: 0.25)

    /// 探索率・晴れた量（0〜1）に応じた色。少しでも晴れていれば明るくし、多いほど黄緑に寄せる。
    static func heat(_ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        return Color(red: 0.37 + 0.45 * t, green: 0.86 + 0.09 * t, blue: 0.67 - 0.35 * t)
    }

    /// 大陸ごとの色（世界のページ）。
    static func continent(_ code: String) -> Color {
        switch code {
        case "AS": Color(red: 0.55, green: 0.85, blue: 0.62)
        case "EU": Color(red: 0.27, green: 0.78, blue: 0.66)
        case "AF": Color(red: 0.68, green: 0.85, blue: 0.40)
        case "NA": Color(red: 0.45, green: 0.82, blue: 0.52)
        case "SA": Color(red: 0.22, green: 0.70, blue: 0.45)
        case "OC": Color(red: 0.60, green: 0.90, blue: 0.48)
        case "AN": Color(red: 0.72, green: 0.84, blue: 0.95)
        default: Color(red: 0.50, green: 0.75, blue: 0.70)
        }
    }

    static func number(_ value: Double, fraction: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fraction)).grouping(.automatic))
    }

    /// 探索率（%）。世界の霧のように桁を多めに出す。
    static func percent(_ ratio: Double) -> String {
        guard ratio > 0 else { return "0%" }
        return (ratio * 100).formatted(.number.precision(.significantDigits(1...10))) + "%"
    }
}

// MARK: - パスポートの表紙

private struct PassportCard: View {
    let parent: Int?
    let catalog: RegionCatalog
    let stats: RegionStats

    var body: some View {
        let explored = parent.map { stats.entry($0).areaKm2 } ?? stats.totalAreaKm2
        let total = parent.map { catalog.regions[$0].areaKm2 } ?? 510_072_000
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let parent, let flag = PassportPage.flag(catalog.regions[parent].flag) {
                            Text(flag).font(.title2)
                        }
                        Text(parent.map { catalog.regions[$0].name } ?? "パスポート")
                            .font(.title2.weight(.bold))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Text("\(Passport.number(total, fraction: 0)) km²")
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
                Spacer(minLength: 8)
                Text(code)
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundStyle(Passport.green)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("探索済みエリア").font(.caption).foregroundStyle(.secondary)
                Text("\(Passport.number(explored, fraction: 6)) km²").font(.body.weight(.semibold)).monospacedDigit()
                Text(Passport.percent(explored / total)).font(.body.weight(.semibold)).monospacedDigit()
            }
            if let parent, catalog.municipalityCounts[parent] > 1, catalog.regions[parent].level == .country {
                Label("\(stats.entry(parent).visitedMunicipalities) / \(catalog.municipalityCounts[parent]) 市区町村",
                      systemImage: "building.2")
                    .font(.callout).monospacedDigit()
            }
            notes
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 大きく出す地域コード（世界 W、大陸と国はその大陸、日本の中は JP）。
    private var code: String {
        guard let parent else { return "W" }
        var i = parent
        while let p = catalog.regions[i].parent {
            if catalog.regions[i].level == .country, catalog.regions[i].code == "JPN", i != parent { return "JP" }
            i = p
        }
        return catalog.regions[i].code
    }

    @ViewBuilder
    private var notes: some View {
        if parent == nil, stats.unassigned.bits > 0 {
            Text("どの国にも入らない分（海上など）\(Passport.number(stats.unassigned.areaKm2, fraction: 3)) km²")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let parent, catalog.regions[parent].level == .country, !catalog.children[parent].isEmpty {
            let own = stats.ownAreaKm2(parent, catalog: catalog)
            if own > 0.0005 {
                Text("どの都道府県にも入らない分（境界の簡略化による海岸沿いなど）\(Passport.number(own, fraction: 3)) km²")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - マス目の縮図

private struct PixelMapView: View {
    let pixels: PixelMap
    let parent: Int?
    let catalog: RegionCatalog
    let stats: RegionStats
    let territory: (visited: Int, total: Int, title: String)?
    let open: (Int) -> Void
    @State private var hovered: Int?

    private var isLeaf: Bool { pixels.isLeaf }
    private var showsCountries: Bool { pixels.showsCountries }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let cell = geo.size.width / Double(pixels.cols)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(context, cell: cell) }
                    labels(cell: cell)
                    if let territory {
                        territoryBadge(territory).padding(8)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hovered = region(at: p, cell: cell) } else { hovered = nil }
                }
                .onTapGesture { p in
                    if let r = region(at: p, cell: cell), !isLeaf { open(target(of: r)) }
                }
            }
            .aspectRatio(Double(pixels.cols) / Double(pixels.rows), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(hoverText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// マスを押したときに開く地域（世界のページでは国ではなく大陸）。
    private func target(of r: Int) -> Int {
        parent == nil ? (catalog.regions[r].parent ?? r) : r
    }

    private func region(at p: CGPoint, cell: Double) -> Int? {
        let c = Int(p.x / cell), r = Int(p.y / cell)
        guard c >= 0, c < pixels.cols, r >= 0, r < pixels.rows else { return nil }
        let v = pixels.value(col: c, row: r)
        return v >= 0 ? Int(v) : nil
    }

    private var hoverText: String {
        guard let h = hovered else {
            if isLeaf { return "マスの明るさは、マスの面積のうち晴れた割合" }
            if !showsCountries { return "明るさはこのページの中での探索率の比べ（いちばん高い地域が最も明るい）" }
            return "マスを押すとその地域を開きます"
        }
        let e = stats.entry(h)
        if !showsCountries, !isLeaf, e.bits > 0 {
            return "\(catalog.regions[h].name)　\(Passport.number(e.areaKm2, fraction: 3)) km²　\(Passport.percent(rate(h)))"
        }
        let name = parent == nil ? "\(catalog.regions[h].name)（\(catalog.regions[target(of: h)].name)）" : catalog.regions[h].name
        return e.bits > 0 ? "\(name)　\(Passport.number(e.areaKm2, fraction: 3)) km²" : "\(name)　まだ行っていない"
    }

    private func rate(_ r: Int) -> Double { stats.rate(r, catalog: catalog) }

    /// このページで探索率がいちばん高い地域の探索率（日本・都道府県・政令指定都市のページで、明るさの基準にする）。
    private var pageMaxRate: Double {
        guard let parent else { return 0 }
        return catalog.children[parent].map(rate).max() ?? 0
    }

    /// 明るさの幅（桁）。いちばん高い探索率を最も明るく、その 1/1000 以下を最も暗くする。
    private static let relativeDecades = 3.0

    /// 子を持たない地域で、マスの面積に対する晴れた割合の幅。0.01% で最も暗く、20% で最も明るい。
    private static let densityRange = (low: 1e-4, high: 0.2)

    private func color(of v: Int32, index i: Int, maxRate: Double) -> Color {
        guard v >= 0 else { return v == PixelMap.otherLand ? Passport.otherLand : .clear }
        let r = Int(v)
        if isLeaf {
            let bits = pixels.heat?[i] ?? 0
            guard bits > 0 else { return Passport.land }
            // マスの面積（ビット数）で割って、地域の大きさによらない密度にする
            let side = (pixels.frame.maxX - pixels.frame.minX) / Double(pixels.cols)
            let density = Double(bits) / (side * side)
            let (low, high) = Self.densityRange
            return Passport.heat(log10(density / low) / log10(high / low))
        }
        let e = stats.entry(r)
        if parent == nil {
            let base = Passport.continent(catalog.regions[catalog.regions[r].parent ?? r].code)
            return e.bits > 0 ? base : base.opacity(0.35)
        }
        guard e.bits > 0 else { return Passport.land }
        if showsCountries { return Passport.mint }
        // このページの中での相対：探索率がいちばん高い地域を最も明るくし、桁の差で暗くする
        guard maxRate > 0 else { return Passport.heat(0) }
        return Passport.heat(1 + log10(rate(r) / maxRate) / Self.relativeDecades)
    }

    private func draw(_ context: GraphicsContext, cell: Double) {
        let size = CGSize(width: cell * Double(pixels.cols), height: cell * Double(pixels.rows))
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Passport.sea))
        var grid = Path()
        for c in 0...pixels.cols {
            grid.move(to: CGPoint(x: Double(c) * cell, y: 0))
            grid.addLine(to: CGPoint(x: Double(c) * cell, y: size.height))
        }
        for r in 0...pixels.rows {
            grid.move(to: CGPoint(x: 0, y: Double(r) * cell))
            grid.addLine(to: CGPoint(x: size.width, y: Double(r) * cell))
        }
        context.stroke(grid, with: .color(Passport.grid), lineWidth: 0.5)
        let gap = cell > 4 ? 0.6 : 0
        let maxRate = pageMaxRate
        for (i, v) in pixels.cells.enumerated() where v != PixelMap.sea {
            let rect = CGRect(x: Double(i % pixels.cols) * cell + gap / 2, y: Double(i / pixels.cols) * cell + gap / 2,
                              width: cell - gap, height: cell - gap)
            context.fill(Path(rect), with: .color(color(of: v, index: i, maxRate: maxRate)))
        }
    }

    /// 世界：大陸ごとの行った国の数。大陸：行った国の国旗と、まだの国の点。
    @ViewBuilder
    private func labels(cell: Double) -> some View {
        if parent == nil {
            ForEach(pixels.bubbles, id: \.index) { b in
                Text("\(b.count)")
                    .font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Passport.green.opacity(0.85), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 1.5))
                    .position(x: b.col * cell, y: b.row * cell)
                    .allowsHitTesting(false)
            }
        } else if showsCountries {
            ForEach(Array(pixels.labels.keys).sorted(), id: \.self) { r in
                let l = pixels.labels[r]!
                let p = CGPoint(x: (Double(l.col) + 0.5) * cell, y: (Double(l.row) + 0.5) * cell)
                Group {
                    if stats.entry(r).bits > 0 {
                        Text(PassportPage.flag(catalog.regions[r].flag) ?? "🏳️")
                            .font(.system(size: 15))
                            .shadow(color: .black.opacity(0.4), radius: 1)
                    } else {
                        Circle().fill(Passport.dot).frame(width: 5, height: 5)
                    }
                }
                .position(p)
                .allowsHitTesting(false)
            }
        }
    }

    private func territoryBadge(_ t: (visited: Int, total: Int, title: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(t.visited)").font(.title2.weight(.heavy)).monospacedDigit()
                Text("/\(t.total)").font(.callout.weight(.semibold)).monospacedDigit().opacity(0.8)
            }
            Text(t.title).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Passport.green.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }
}

// MARK: - ランキングの 1 行

private struct RankRow: View {
    let rank: Int?
    let index: Int
    let catalog: RegionCatalog
    let stats: RegionStats

    var body: some View {
        let e = stats.entry(index)
        let region = catalog.regions[index]
        HStack(alignment: .center, spacing: 8) {
            Text(rank.map { "\($0)" } ?? "")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            if let flag = PassportPage.flag(region.flag) {
                Text(flag).font(.title3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(region.name).foregroundStyle(e.bits > 0 ? .primary : .secondary).lineLimit(1)
                if let sub = subtitle(region, e) {
                    Text(sub).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            if e.bits > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Passport.number(e.areaKm2, fraction: 3)) km²").monospacedDigit()
                    if region.areaKm2 > 0 {
                        Text(Passport.percent(e.areaKm2 / region.areaKm2))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private func subtitle(_ region: RegionCatalog.Region, _ e: RegionStats.Entry) -> String? {
        if region.level == .continent {
            let countries = catalog.children[index]
            return "\(countries.filter { stats.entry($0).bits > 0 }.count) / \(countries.count) テリトリー"
        }
        let count = catalog.municipalityCounts[index]
        return count > 1 ? "\(e.visitedMunicipalities) / \(count) 市区町村" : nil
    }
}
