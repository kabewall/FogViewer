import Foundation
import MapKit

/// バッジの状態。霧が読み直されるたびに、開いているときだけ判定し直す。
@MainActor
final class BadgeModel: ObservableObject {
    @Published private(set) var badges: [Badge] = []
    @Published private(set) var isComputing = false
    @Published private(set) var errorMessage: String?
    /// 選んでいるバッジ。
    @Published private(set) var selectedID: String?
    /// 地図に輪郭を出している地域（都道府県のメッシュのバッジ）。
    @Published private(set) var highlight: RegionHighlight?
    /// 地図に立てている目標の地点（交点・岬のバッジ）。
    @Published private(set) var pins: BadgePins?

    private var catalog: RegionCatalog?
    /// 境界だけで決まる下ごしらえ。一度作ったら使い回す。
    private var geography: BadgeGeography?
    private var computedGeneration: Int?
    private var pending: (fog: FogData, generation: Int)?
    private var isOpen = false

    /// 霧が変わっていれば判定し直す。判定中に呼ばれたら、終わってから最新の分をやり直す。
    func update(fog: FogData, generation: Int) {
        isOpen = true
        guard generation > 0, generation != computedGeneration else { return }
        guard !isComputing else { pending = (fog, generation); return }
        isComputing = true
        let loaded = catalog, prepared = geography
        Task.detached(priority: .userInitiated) {
            let result = Result { () -> (RegionCatalog, BadgeGeography, [Badge]) in
                let catalog = try loaded ?? RegionCatalog.shared.get()
                let geography = prepared ?? BadgeGeography.build(catalog: catalog)
                return (catalog, geography, BadgeStats.compute(fog: fog, catalog: catalog, geography: geography))
            }
            await MainActor.run {
                self.isComputing = false
                switch result {
                case .success(let (catalog, geography, badges)):
                    self.catalog = catalog
                    self.geography = geography
                    self.badges = badges
                    self.computedGeneration = generation
                    self.errorMessage = nil
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

    /// 一覧を閉じたら、やり残しの判定はしない（結果と下ごしらえは小さいので残す）。
    func close() {
        isOpen = false
        pending = nil
    }

    /// バッジの対象を地図に出し、そこへ寄せる。同じバッジをもう一度選ぶと選ぶのをやめる。
    func select(_ badge: Badge?, map: MapController) {
        guard let badge, badge.id != selectedID else {
            selectedID = nil
            highlight = nil
            pins = nil
            return
        }
        selectedID = badge.id
        switch badge.target {
        case .region(let index)?:
            pins = nil
            guard let catalog else { return }
            highlight = RegionHighlight(index: index, outline: catalog.outline(of: index))
            map.show(rect: catalog.regions[index].mainBounds.mapRect)
        case .points(let points)?:
            highlight = nil
            let annotations = points.map { BadgePin(point: $0) }
            pins = BadgePins(id: badge.id, annotations: annotations)
            map.show(rect: annotations.reduce(MKMapRect.null) { rect, pin in
                // 1 点だけでも周りが見えるよう、地点ごとに数 km の幅を持たせる
                let p = MKMapPoint(pin.coordinate), side = MKMapPointsPerMeterAtLatitude(pin.coordinate.latitude) * 3000
                return rect.union(MKMapRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
            })
        case nil:
            highlight = nil
            pins = nil
        }
    }
}

/// 地図に立てるバッジの目標地点。行ったかどうかで色を変える。
final class BadgePin: MKPointAnnotation {
    let reached: Bool

    init(point: Badge.Point) {
        reached = point.reached
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
        title = point.name
        subtitle = point.reached ? "到達済み" : "まだ"
    }
}

/// 地図に立てるピンのまとまり。バッジの番号で比べる。
struct BadgePins: Equatable {
    let id: String
    let annotations: [BadgePin]

    static func == (a: BadgePins, b: BadgePins) -> Bool { a.id == b.id }
}
