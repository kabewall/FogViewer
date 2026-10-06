import Foundation
import os

/// launchd に登録する見張り役。アプリ本体の実行ファイルを `--watch` 付きで起動させる。
///
/// 別の実行ファイルにすると、iCloud の他アプリのフォルダを読む許可を別に求められ、
/// 画面のない見張り役では許可ダイアログに気づけず止まってしまうため、本体を使い回す。
enum WatchAgent {
    static let watchArgument = "--watch"
    static let label = "com.kabewall.FogViewer.watch"
    /// 変化がなくても確認する間隔（秒）。変化は WatchPaths ですぐ拾う。
    static let checkInterval = 15 * 60

    private static let logger = Logger(subsystem: "com.kabewall.FogViewer", category: "watch")

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL { HistoryStore.defaultDirectory.appendingPathComponent("watch.log") }

    // MARK: - 見張り役として 1 回動く

    static func runOnce() -> Int32 {
        do {
            let store = try HistoryStore()
            var recorder = HistoryRecorder(syncFolder: FogStore.syncFolder, store: store)
            recorder.log = { message in
                logger.info("\(message, privacy: .public)")
                appendLog(message)
            }
            guard FileManager.default.fileExists(atPath: FogStore.syncFolder.path) else {
                recorder.log("Sync フォルダがありません")
                return 0
            }
            let outcome = try recorder.checkOnce()
            if outcome != .unchanged { recorder.log("結果: \(outcome)") }
            return 0
        } catch {
            logger.error("\(String(describing: error), privacy: .public)")
            appendLog("エラー: \(error)")
            return 1
        }
    }

    private static func appendLog(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: logURL)
        }
    }

    // MARK: - 登録と解除（アプリ本体から呼ぶ）

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// 登録済みの plist が今の実行ファイルを指しているか。アプリを移動したら登録し直す。
    static var isUpToDate: Bool {
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let args = dict["ProgramArguments"] as? [String] else { return false }
        return args.first == Bundle.main.executablePath
    }

    static func install() throws {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, watchArgument],
            "WatchPaths": [FogStore.syncFolder.path],
            "StartInterval": checkInterval,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardErrorPath": logURL.path,
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: HistoryStore.defaultDirectory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try data.write(to: plistURL)
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    static func uninstall() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// 今すぐ 1 回動かす。
    static func kick() {
        launchctl(["kickstart", "gui/\(getuid())/\(label)"])
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
