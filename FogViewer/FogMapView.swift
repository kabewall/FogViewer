import MapKit
import SwiftUI

/// MKMapView に霧オーバーレイを重ねた地図。
struct FogMapView: NSViewRepresentable {
    let fog: FogData
    let generation: Int
    /// 番号 `since` の霧から今の霧までに変わった範囲（タイムラプス用）。分かればそこだけ描き直す。
    var changed: (since: Int, rect: MKMapRect)? = nil
    let style: BaseMapStyle
    let terrain3D: Bool
    let fogEnabled: Bool
    let density: FogDensity
    let color: FogColor
    let lineWidth: FogLineWidth
    /// 輪郭を出す地域（地域ランキングで選んだもの）。
    var highlight: RegionHighlight? = nil
    let controller: MapController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.showsScale = true
        map.isRotateEnabled = true
        applyStyle(to: map, coordinator: context.coordinator)
        controller.mapView = map
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.style != style || c.terrain3D != terrain3D {
            applyStyle(to: map, coordinator: c)
        }
        if c.highlight != highlight {
            if let old = c.highlight { map.removeOverlay(old.outline) }
            if let highlight { map.addOverlay(highlight.outline, level: .aboveLabels) }
            c.highlight = highlight
        }
        // 霧は不変値なので、中身か表示設定が変わったときだけ描き直す。
        let key = OverlayKey(generation: generation, enabled: fogEnabled, density: density, color: color, lineWidth: lineWidth)
        guard key != c.overlayKey else { return }
        // 中身だけが変わったとき（タイムラプスの再生や読み直し）は、載せ替えずに差し替えて描き直す。
        // 載せ替えると描き終わるまで霧が消え、再生中にちらつく。
        if var old = c.overlayKey, let overlay = c.overlay {
            let previous = old.generation
            old.generation = key.generation
            if old == key {
                c.overlayKey = key
                overlay.fog = fog
                guard let renderer = map.renderer(for: overlay) else { return }
                if let changed, changed.since == previous {
                    // 再生中は毎コマ画面全体を描き直すと重いので、変わった範囲だけにする。
                    // 晴れた部分は最小の太さや円の分だけ広がるので、その分（と余裕）を足す。
                    guard !changed.rect.isNull else { return }
                    let mapPointsPerPoint = map.visibleMapRect.width / max(map.bounds.width, 1)
                    let margin = (lineWidth.points / 2 + 4) * mapPointsPerPoint
                        + 2 * MKMapSize.world.width / Double(1 << FowFormat.worldBitsLog2)
                    renderer.setNeedsDisplay(changed.rect.insetBy(dx: -margin, dy: -margin))
                } else {
                    renderer.setNeedsDisplay()
                }
                return
            }
        }
        c.overlayKey = key
        if let old = c.overlay { map.removeOverlay(old) }
        c.overlay = nil
        if fogEnabled {
            let overlay = FogOverlay(fog: fog, opacity: density.opacity, color: color.rgb, minLineWidth: lineWidth.points)
            // 地域の輪郭より下に置く
            map.insertOverlay(overlay, at: 0, level: .aboveLabels)
            c.overlay = overlay
        }
    }

    /// 地図の種類と立体表示を反映する。立体をやめるときは傾きも戻す。
    private func applyStyle(to map: MKMapView, coordinator c: Coordinator) {
        map.preferredConfiguration = style.configuration(terrain3D: terrain3D)
        map.isPitchEnabled = terrain3D
        map.showsPitchControl = terrain3D
        if !terrain3D, map.camera.pitch != 0 {
            let camera = map.camera.copy() as! MKMapCamera
            camera.pitch = 0
            map.setCamera(camera, animated: true)
        }
        c.style = style
        c.terrain3D = terrain3D
    }

    struct OverlayKey: Equatable {
        var generation: Int
        var enabled: Bool
        var density: FogDensity
        var color: FogColor
        var lineWidth: FogLineWidth
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var style: BaseMapStyle?
        var terrain3D: Bool?
        var overlay: FogOverlay?
        var overlayKey: OverlayKey?
        var highlight: RegionHighlight?
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let fog = overlay as? FogOverlay {
                let scale = mapView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                return FogOverlayRenderer(overlay: fog, backingScale: Double(scale))
            }
            if let outline = overlay as? MKMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: outline)
                renderer.strokeColor = .systemOrange
                renderer.lineWidth = 2.5
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let id = "pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.canShowCallout = true
            view.displayPriority = .required
            return view
        }
    }
}
