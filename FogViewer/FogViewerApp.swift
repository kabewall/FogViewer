import SwiftUI

/// 起動の入口。`--watch` 付きなら画面を出さずに履歴を 1 回記録して終わる（launchd から呼ばれる）。
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains(WatchAgent.watchArgument) {
            exit(WatchAgent.runOnce())
        }
        if let i = CommandLine.arguments.firstIndex(of: "--collapse-purge") {
            exit(runCollapsePurge(CommandLine.arguments[(i + 1)...].compactMap { Int64($0) }))
        }
        if CommandLine.arguments.contains("--backfill") {
            exit(runBackfill())
        }
        FogViewerApp.main()
    }
}

/// `--backfill`：画面を出さずに、取り込んだ GPX・タイムライン JSON から過去の分を埋める。
private func runBackfill() -> Int32 {
    var message: String?
    let started = Date()
    Task.detached { message = await HistoryModel.runBackfill() }
    while message == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    print(message!)
    print(String(format: "elapsed: %.1f s", Date().timeIntervalSince(started)))
    return message!.hasPrefix("埋められませんでした") ? 1 : 0
}

/// `--collapse-purge <ID…>`：連続する iCloud の記録をまとめ、正味で消えたビットを誤記録として履歴から取り除く。
private func runCollapsePurge(_ ids: [Int64]) -> Int32 {
    do {
        let store = try HistoryStore()
        let r = try store.collapseAndPurge(eventIDs: ids)
        print("まとめた記録: \(r.collapsedEvents), 取り除いたビット: \(r.purgedBits), 正味で増えたビット: \(r.netAddedBits), 空になって消した記録: \(r.deletedEmptyEvents)")
        return 0
    } catch {
        print("エラー: \(error)")
        return 1
    }
}

struct FogViewerApp: App {
    @StateObject private var store = FogStore()
    @StateObject private var history = HistoryModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(history)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands { FogCommands(store: store, history: history) }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(history)
        }
    }
}

/// メニューバーの項目。サイドバーを置かないので、たまにしか使わない操作はここから呼ぶ。
private struct FogCommands: Commands {
    @ObservedObject var store: FogStore
    @ObservedObject var history: HistoryModel
    @FocusedObject private var map: MapController?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("GPX・タイムラインを追加…") { chooseImportFiles(into: history) }
                .disabled(!history.canBackfill)
            Button("取り込んだ記録で過去の分を埋める") { history.backfill() }
                .disabled(!history.canBackfill)
        }
        CommandGroup(after: .toolbar) {
            Button("記録全体を表示") {
                if let rect = store.visitedMapRect { map?.show(rect: rect) }
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(map == nil || store.visitedMapRect == nil)
            Button("iCloud から読み直す") { store.reload(force: true) }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
