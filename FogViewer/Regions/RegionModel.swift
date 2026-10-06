import Foundation
import MapKit

/// 地域ランキングの状態。境界は最初に開いたときに読み、霧が読み直されるたびに集計し直す。
@MainActor
final class RegionModel: ObservableObject {
    @Published private(set) var catalog: RegionCatalog?
    @Published private(set) var stats: RegionStats?
    @Published private(set) var isComputing = false
    @Published private(set) var errorMessage: String?
    /// 地図に輪郭を出している地域。
    @Published private(set) var highlight: RegionHighlight?
    /// ランキングでたどってきた地域（世界から順に）。
    @Published var path: [Int] = []

    private var computedGeneration: Int?
    /// 集計に使った霧（縮図で晴れた量を塗るのに使う）。
    private var fog: FogData = .empty
    /// 縮図は開いた地域ごとに作って、集計し直すまでとっておく。キーは地域の番号（世界は -1）。
    private var pixelMaps: [Int: PixelMap] = [:]
    private var pending: (fog: FogData, generation: Int)?
    /// 前回の集計でのブロックごとの判定結果（開いている間だけ持つ）。
    private var classified: RegionStats.Classified = [:]
    /// ランキングを開いているか。閉じたら霧を手放し、やり残しの集計もしない。
    private var isOpen = false

    /// 霧が変わっていれば集計し直す。集計中に呼ばれたら、終わってから最新の分をやり直す。
    func update(fog: FogData, generation: Int) {
        isOpen = true
        guard generation > 0 else { return }
        guard generation != computedGeneration else {
            // 閉じて霧を手放した後に、同じ記録で開き直したとき（霧なしで作った縮図は作り直す）
            if self.fog.blocks.isEmpty, !fog.blocks.isEmpty { pixelMaps = [:] }
            self.fog = fog
            return
        }
        guard !isComputing else { pending = (fog, generation); return }
        isComputing = true
        let loaded = catalog, previous = classified
        Task.detached(priority: .userInitiated) {
            let result = Result { () -> (RegionCatalog, RegionStats, RegionStats.Classified) in
                let catalog = try loaded ?? Self.loadCatalog()
                let (stats, classified) = RegionStats.compute(fog: fog, catalog: catalog, reusing: previous)
                return (catalog, stats, classified)
            }
            await MainActor.run {
                self.isComputing = false
                switch result {
                case .success(let (catalog, stats, classified)):
                    self.catalog = catalog
                    self.stats = stats
                    self.pixelMaps = [:]
                    self.computedGeneration = generation
                    self.errorMessage = nil
                    if self.isOpen {
                        self.fog = fog
                        self.classified = classified
                    }
                case .failure(let error):
                    self.errorMessage = "境界データを読めませんでした: \(error)"
                }
                if self.isOpen, let next = self.pending {
                    self.pending = nil
                    self.update(fog: next.fog, generation: next.generation)
                }
            }
        }
    }

    /// ランキングを閉じたら、集計に使った霧と判定結果を手放す（集計結果と境界は小さいので残す）。
    func close() {
        isOpen = false
        pending = nil
        fog = .empty
        classified = [:]
        pixelMaps = [:]
    }

    nonisolated private static func loadCatalog() throws -> RegionCatalog {
        guard let url = RegionCatalog.bundled else { throw CocoaError(.fileNoSuchFile) }
        return try RegionCatalog.load(url: url)
    }

    func pixelMap(for parent: Int?) -> PixelMap? {
        guard let catalog, let stats else { return nil }
        let key = parent ?? -1
        if let cached = pixelMaps[key] { return cached }
        let map = PixelMap.build(parent: parent, catalog: catalog, stats: stats, fog: fog)
        pixelMaps[key] = map
        return map
    }

    /// 地域の輪郭を地図に出し、そこへ寄せる。
    func select(_ index: Int?, map: MapController) {
        guard let index, let catalog else {
            highlight = nil
            return
        }
        let region = catalog.regions[index]
        if region.rings.isEmpty {
            highlight = nil  // 大陸は輪郭を持たない
        } else if highlight?.index != index {
            highlight = RegionHighlight(index: index, outline: catalog.outline(of: index))
        }
        let visited = stats?.entry(index).visitedBounds ?? .null
        // 離島や海外領土まで含めると広すぎるので、いちばん大きな輪と晴れている範囲に寄せる
        let rect = region.mainBounds.union(visited)
        guard !rect.isNull else { return }
        map.show(rect: rect.mapRect)
    }
}

/// 地図に出す地域の輪郭。番号で比べる（輪郭は番号から決まる）。
struct RegionHighlight: Equatable {
    let index: Int
    let outline: MKMultiPolyline

    static func == (a: RegionHighlight, b: RegionHighlight) -> Bool { a.index == b.index }
}
