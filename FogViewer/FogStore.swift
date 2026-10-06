import Foundation
import MapKit

/// iCloud 上の Fog of World データの読み込み状態。
@MainActor
final class FogStore: ObservableObject {
    @Published private(set) var fog: FogData = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var failedFiles: [String] = []
    @Published private(set) var exploredAreaKm2: Double = 0
    /// 読み込みのたびに増える。地図側で霧の載せ替えに使う。
    @Published private(set) var generation = 0

    nonisolated static let syncFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~com~ollix~FogOfWorld/Documents/Sync")

    /// 前回読み込んだときのフォルダの状態。変わっていなければ読み直さない。
    private var lastSignature: FolderSignature?

    /// - Parameter force: true ならフォルダに変化がなくても読み直す（⌘R など）。
    func reload(force: Bool = false) {
        guard !isLoading else { return }
        isLoading = true
        let folder = Self.syncFolder
        let previous = force ? nil : lastSignature
        Task.detached(priority: .userInitiated) {
            let exists = FileManager.default.fileExists(atPath: folder.path)
            let signature = exists ? FolderSignature(folder: folder) : nil
            if let signature, signature == previous {
                await MainActor.run {
                    self.isLoading = false
                    self.lastLoaded = Date()
                }
                return
            }
            let result = exists ? FogParser.load(syncFolder: folder) : (data: FogData.empty, failures: [String]())
            let area = result.data.exploredAreaKm2
            await MainActor.run {
                self.isLoading = false
                self.lastLoaded = Date()
                self.lastSignature = signature
                if !exists {
                    self.errorMessage = "iCloud に Fog of World の Sync フォルダが見つかりません。\n\(folder.path)"
                    return
                }
                self.errorMessage = nil
                self.failedFiles = result.failures
                self.fog = result.data
                self.exploredAreaKm2 = area
                self.generation += 1
            }
        }
    }

    /// 訪問済み範囲を MapKit の座標系で返す。
    var visitedMapRect: MKMapRect? {
        guard let b = fog.blockBounds else { return nil }
        // MapKit の世界幅 2^28 に対し、ブロック単位の世界幅は 2^16。
        let k: Double = MKMapSize.world.width / Double(FowFormat.worldBlocks)
        let origin = MKMapPoint(x: Double(b.minX) * k, y: Double(b.minY) * k)
        let size = MKMapSize(width: Double(b.maxX - b.minX) * k, height: Double(b.maxY - b.minY) * k)
        return MKMapRect(origin: origin, size: size)
    }
}

/// フォルダ内のファイル名・サイズ・更新日時の組。中身を読まずに変化を検出するのに使う。
/// iCloud 上でダウンロードされていないファイルでも、これらの属性は取得できる。
struct FolderSignature: Equatable, Sendable {
    private let entries: [String: [Double]]

    init(folder: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var entries: [String: [Double]] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            entries[url.lastPathComponent] = [
                Double(values?.fileSize ?? -1),
                values?.contentModificationDate?.timeIntervalSince1970 ?? -1,
            ]
        }
        self.entries = entries
    }
}
