import Foundation

/// 設定ウィンドウに出す履歴の状態。アプリ本体は履歴 DB を読むだけで、書くのは見張り役。
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var isEnabled = WatchAgent.isInstalled
    @Published private(set) var summary: HistorySummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBackfilling = false
    @Published private(set) var backfillMessage: String?

    /// 登録済みの見張り役が、今動いているのとは別の実行ファイルを指している。
    /// テストや Debug ビルドで勝手に書き換えないよう、自動では登録し直さずに知らせるだけにする。
    var needsReinstall: Bool { isEnabled && !WatchAgent.isUpToDate }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try WatchAgent.install() } else { WatchAgent.uninstall() }
            errorMessage = nil
        } catch {
            errorMessage = "登録できませんでした: \(error.localizedDescription)"
        }
        isEnabled = WatchAgent.isInstalled
        refresh()
    }

    func recordNow() {
        WatchAgent.kick()
    }

    /// 取り込んだ記録（GPX・タイムライン JSON）から、過去の分に日時をつける。
    func backfill() {
        guard !isBackfilling else { return }
        isBackfilling = true
        backfillMessage = "取り込んだ記録を読み込み中…"
        Task.detached(priority: .userInitiated) {
            let outcome = await Self.runBackfill()
            await MainActor.run {
                self.isBackfilling = false
                self.backfillMessage = outcome
                self.refresh()
            }
        }
    }

    /// 埋め合わせを 1 回実行して、結果の説明文を返す（コマンド実行からも使う）。
    nonisolated static func runBackfill() async -> String {
        do {
            let store = try HistoryStore()
            guard try store.hasBaseline() else {
                return "記録開始の全量がまだありません。先に「変化を記録する」をオンにしてください"
            }
            let (points, sources) = GPXBackfill.importedPoints()
            let r = try GPXBackfill().run(points: points, store: store)
            let pct = r.baselineBits > 0 ? Double(r.assignedBits) / Double(r.baselineBits) * 100 : 0
            let range = [r.earliest, r.latest].compactMap { $0?.formatted(date: .abbreviated, time: .omitted) }
                .joined(separator: "〜")
            return "\(sources.count) ファイル・\(r.pointCount.formatted()) 地点から、"
                + "\(r.assignedBits.formatted()) / \(r.baselineBits.formatted()) ビット（\(String(format: "%.1f", pct))%）に日時をつけました"
                + "（地点の近く \(r.timelineBits.formatted())・線をたどって \(r.lineBits.formatted())、\(range)）"
        } catch {
            return "埋められませんでした: \(error)"
        }
    }

    /// ファイルをアプリの取り込みフォルダにコピーして、過去の分を作り直す。
    func addImportFiles(_ urls: [URL]) {
        do {
            for url in urls { try GPXBackfill.addImportFile(url) }
            backfill()
        } catch {
            backfillMessage = "追加できませんでした: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard FileManager.default.fileExists(atPath: HistoryStore.defaultURL.path) else {
            summary = nil
            return
        }
        Task.detached(priority: .utility) {
            let result = Result { try HistoryStore(readOnly: true).summary() }
            await MainActor.run {
                switch result {
                case .success(let s): self.summary = s
                case .failure(let e): self.errorMessage = "履歴を読めませんでした: \(e)"
                }
            }
        }
    }
}
