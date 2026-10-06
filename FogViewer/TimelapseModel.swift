import Foundation
import MapKit

/// タイムラプスの再生状態。
@MainActor
final class TimelapseModel: ObservableObject {
    enum Speed: Double, CaseIterable, Identifiable {
        case day = 1, week = 7, month = 30, year = 365
        var id: Double { rawValue }
        var title: String {
            switch self {
            case .day: "1日 / 秒"
            case .week: "1週間 / 秒"
            case .month: "1か月 / 秒"
            case .year: "1年 / 秒"
            }
        }
    }

    @Published private(set) var isActive = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    /// 今の再生位置の霧と、地図に描き直しを知らせるための番号。
    @Published private(set) var fog: FogData = .empty
    @Published private(set) var generation = 0
    /// 直前の番号から今の番号までに霧が変わった範囲。nil なら全体を描き直す。
    private(set) var changedRect: MKMapRect?
    @Published private(set) var currentTime = Date()
    @Published private(set) var areaKm2 = 0.0
    @Published var speed: Speed = .month
    /// 変化のない期間を飛ばす。
    @Published var skipIdle = true
    /// 新しく晴れた場所へ地図を動かす。
    @Published var follow = false

    private(set) var start = Date()
    private(set) var end = Date()
    private var cursor: TimelapseCursor?
    private var timer: Timer?
    private var lastFollow = Date.distantPast
    weak var map: MapController?

    static let frameInterval: TimeInterval = 1.0 / 20

    func open() {
        guard !isActive, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { () -> TimelapseData in
                guard FileManager.default.fileExists(atPath: HistoryStore.defaultURL.path) else {
                    throw SQLiteDatabase.Error(message: "履歴がまだありません。設定の「変化を記録する」をオンにしてください")
                }
                return try TimelapseData.load(from: try HistoryStore(readOnly: true))
            }
            await MainActor.run {
                self.isLoading = false
                switch result {
                case .success(let data):
                    guard let start = data.start, let end = data.end else {
                        self.errorMessage = "再生できる履歴がありません"
                        return
                    }
                    self.start = start
                    self.end = end
                    self.cursor = TimelapseCursor(data: data)
                    self.isActive = true
                    self.seek(to: start)
                case .failure(let error):
                    self.errorMessage = "\(error)"
                }
            }
        }
    }

    func close() {
        pause()
        isActive = false
        cursor = nil
        fog = .empty
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard isActive, !isPlaying else { return }
        if currentTime >= end { seek(to: start) }
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    /// スライダーなどで位置を変える。
    func seek(to time: Date) {
        guard var cursor else { return }
        let t = min(max(time, start), end)
        cursor.move(to: t)
        self.cursor = cursor
        currentTime = t
        publish(cursor, changedRect: nil)
    }

    private func tick() {
        guard var cursor else { return }
        var t = currentTime.addingTimeInterval(speed.rawValue * 86_400 * Self.frameInterval)
        // 次の変化まで 1 秒以上かかるなら、そこまで飛ばす
        if skipIdle, let next = cursor.nextStepTime, next > t,
           next.timeIntervalSince(currentTime) > speed.rawValue * 86_400 {
            t = next
        }
        t = min(t, end)
        let before = cursor.applied
        let added = cursor.move(to: t)
        self.cursor = cursor
        currentTime = t
        if cursor.applied > before {
            publish(cursor, changedRect: Self.mapRect(of: cursor.data.steps[before..<cursor.applied]))
        } else if cursor.applied != before {
            publish(cursor, changedRect: nil)
        }
        if follow, !added.isEmpty { followNewArea(added) }
        if t >= end { pause() }
    }

    private func publish(_ cursor: TimelapseCursor, changedRect: MKMapRect?) {
        self.changedRect = changedRect
        fog = cursor.fogData
        areaKm2 = cursor.areaKm2
        generation += 1
    }

    /// 段で晴れた・霧に戻ったビットを囲む範囲。
    private static func mapRect(of steps: ArraySlice<TimelapseData.Step>) -> MKMapRect {
        var minX = UInt64.max, minY = UInt64.max, maxX: UInt64 = 0, maxY: UInt64 = 0
        for step in steps {
            for list in [step.added, step.removed] {
                for b in list {
                    let x = b >> 32, y = b & 0xFFFF_FFFF
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX else { return .null }
        let k = MKMapSize.world.width / Double(1 << FowFormat.worldBitsLog2)
        return MKMapRect(x: Double(minX) * k, y: Double(minY) * k,
                         width: Double(maxX - minX + 1) * k, height: Double(maxY - minY + 1) * k)
    }

    /// 新しく晴れた場所が画面の外なら、そこへ地図を動かす（動かしすぎないよう 1.5 秒に 1 回まで）。
    private func followNewArea(_ bits: [UInt64]) {
        guard let mapView = map?.mapView, Date().timeIntervalSince(lastFollow) > 1.5 else { return }
        let k = MKMapSize.world.width / Double(1 << FowFormat.worldBitsLog2)
        var rect = MKMapRect.null
        for b in bits {
            let p = MKMapPoint(x: Double(b >> 32) * k, y: Double(b & 0xFFFF_FFFF) * k)
            rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: k, height: k)))
        }
        guard !rect.isNull, !mapView.visibleMapRect.contains(rect) else { return }
        // 小さすぎる範囲に寄りすぎないよう、最低でも 20 km 四方は見せる
        let minSide = 20_000 * MKMapPointsPerMeterAtLatitude(rect.origin.coordinate.latitude)
        if rect.width < minSide || rect.height < minSide {
            rect = rect.insetBy(dx: -(max(minSide - rect.width, 0) / 2), dy: -(max(minSide - rect.height, 0) / 2))
        }
        lastFollow = Date()
        map?.show(rect: rect)
    }
}
