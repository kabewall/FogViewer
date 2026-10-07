import CoreLocation
import MapKit

enum BaseMapStyle: String, CaseIterable, Identifiable {
    case explore, satellite, hybrid
    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: "詳細マップ"
        case .satellite: "航空写真"
        case .hybrid: "ハイブリッド"
        }
    }

    /// - Parameter terrain3D: 立体の地形を出すか。出すと地図が重く、メモリも多く使う。
    func configuration(terrain3D: Bool) -> MKMapConfiguration {
        let elevation: MKMapConfiguration.ElevationStyle = terrain3D ? .realistic : .flat
        switch self {
        case .explore: return MKStandardMapConfiguration(elevationStyle: elevation)
        case .satellite: return MKImageryMapConfiguration(elevationStyle: elevation)
        case .hybrid: return MKHybridMapConfiguration(elevationStyle: elevation)
        }
    }
}

enum FogDensity: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "薄い"
        case .medium: "ふつう"
        case .high: "濃い"
        }
    }

    var opacity: Double {
        switch self {
        case .low: 0.6
        case .medium: 0.8
        case .high: 0.92
        }
    }
}

/// 霧の色。
enum FogColor: String, CaseIterable, Identifiable {
    case navy, black, white
    var id: String { rawValue }

    var title: String {
        switch self {
        case .navy: "紺"
        case .black: "黒"
        case .white: "白"
        }
    }

    var rgb: FogRGB {
        switch self {
        case .navy: FogRGB(r: 0.07, g: 0.11, b: 0.24)
        case .black: FogRGB(r: 0.02, g: 0.02, b: 0.03)
        case .white: FogRGB(r: 0.94, g: 0.95, b: 0.97)
        }
    }
}

/// 晴れた部分の最小の太さ。記録は幅 1 ビット（約 8 m）の線なので、縮小すると見えなくなる。
/// iOS の Fog of World は記録の点ごとに大きな円で霧を抜くので、`wide` がそれに近い。
/// その円は地図上の大きさが決まっていて、縮小すると画面上では細くなる。
enum FogLineWidth: String, CaseIterable, Identifiable {
    case off, thin, medium, thick, wide
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "記録どおり"
        case .thin: "細い（2pt）"
        case .medium: "ふつう（3pt）"
        case .thick: "太い（5pt）"
        case .wide: "iOS 版に近い"
        }
    }

    /// 画面上のポイント数。
    var points: Double {
        switch self {
        case .off: 0
        case .thin: 2
        case .medium: 3
        case .thick: 5
        case .wide: 3
        }
    }

    /// 1 ビットを抜く円の直径（ビット数）。地図上の大きさなので縮小すると細くなる。
    /// 16 ビットは日本の緯度で約 120 m。
    var bitDiameter: Double {
        self == .wide ? 16 : 0
    }
}

/// SwiftUI から MKMapView を操作するための窓口。
@MainActor
final class MapController: NSObject, ObservableObject, CLLocationManagerDelegate {
    weak var mapView: MKMapView?
    @Published var selectedItem: MKMapItem?
    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func show(rect: MKMapRect, animated: Bool = true) {
        guard let mapView else { return }
        let padded = mapView.mapRectThatFits(rect, edgePadding: NSEdgeInsets(top: 60, left: 60, bottom: 60, right: 60))
        mapView.setVisibleMapRect(padded, animated: animated)
    }

    func show(item: MKMapItem) {
        guard let mapView else { return }
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        let pin = MKPointAnnotation()
        pin.coordinate = item.placemark.coordinate
        pin.title = item.name
        mapView.addAnnotation(pin)
        let region = MKCoordinateRegion(center: pin.coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)
        mapView.setRegion(region, animated: true)
        selectedItem = item
    }

    func clearSelection() {
        selectedItem = nil
        guard let mapView else { return }
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
    }

    func zoom(by factor: Double) {
        guard let mapView else { return }
        var region = mapView.region
        region.span.latitudeDelta = min(region.span.latitudeDelta * factor, 170)
        region.span.longitudeDelta = min(region.span.longitudeDelta * factor, 350)
        mapView.setRegion(region, animated: true)
    }

    func showUserLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            startTracking()
        default:
            break
        }
    }

    private func startTracking() {
        guard let mapView else { return }
        mapView.showsUserLocation = true
        mapView.setUserTrackingMode(.follow, animated: true)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedAlways || status == .authorized { self.startTracking() }
        }
    }
}
