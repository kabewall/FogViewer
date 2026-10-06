import SwiftUI
import UniformTypeIdentifiers

/// 設定ウィンドウ（⌘,）。ふだん地図を見るときには要らない、履歴の設定と記録の詳しい状態を置く。
struct SettingsView: View {
    var body: some View {
        TabView {
            HistorySettings()
                .tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
            DetailSettings()
                .tabItem { Label("詳細", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 520)
    }
}

/// 霧の変化の記録（見張り役）と、GPX・タイムラインからの埋め合わせ。
private struct HistorySettings: View {
    @EnvironmentObject private var history: HistoryModel

    var body: some View {
        Form {
            Section {
                Toggle("変化を記録する", isOn: Binding(get: { history.isEnabled }, set: { history.setEnabled($0) }))
                if history.needsReinstall {
                    Text("見張り役は別の場所のアプリを使っています").foregroundStyle(.orange)
                    Button("このアプリで登録し直す") { history.setEnabled(true) }
                }
                if let message = history.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Mac にログインしている間、iCloud の記録の変化を確認して差分を保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("GPX・タイムラインを追加…") { chooseImportFiles(into: history) }
                    .disabled(!history.canBackfill)
                Button(history.isBackfilling ? "埋めています…" : "取り込んだ記録で過去の分を埋める") { history.backfill() }
                    .disabled(!history.canBackfill)
                if let message = history.backfillMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("過去の分")
            } footer: {
                Text(history.summary?.baselineAt == nil
                     ? "先に「変化を記録する」をオンにしてください。"
                     : "取り込んだ GPX・Google タイムラインから、霧のビットに最初に行った日時を推測してつけます。再実行すると作り直します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { history.refresh() }
    }
}

/// 読み込んだ記録と履歴の数値。動作の確認用。
private struct DetailSettings: View {
    @EnvironmentObject private var store: FogStore
    @EnvironmentObject private var history: HistoryModel

    var body: some View {
        Form {
            Section("iCloud の記録") {
                LabeledContent("探索面積", value: String(format: "%.2f km²", store.exploredAreaKm2))
                LabeledContent("ブロック数", value: store.fog.blocks.count.formatted())
                if let date = store.lastLoaded {
                    LabeledContent("最終読み込み", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if !store.failedFiles.isEmpty {
                    DisclosureGroup("読めなかったファイル（\(store.failedFiles.count)）") {
                        ForEach(store.failedFiles, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }
                    .foregroundStyle(.orange)
                }
                Button(store.isLoading ? "読み込み中…" : "iCloud から読み直す") { store.reload(force: true) }
                    .disabled(store.isLoading)
            }

            Section("履歴") {
                if let s = history.summary {
                    if let base = s.baselineAt {
                        LabeledContent("記録開始", value: base.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("変化の回数", value: "\(s.updateCount)")
                    LabeledContent("開始後に晴れたビット", value: s.bitsAddedSinceBaseline.formatted())
                    if let last = s.lastEventAt {
                        LabeledContent("最後の変化", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let checked = s.lastCheckedAt {
                        LabeledContent("最後の確認", value: checked.formatted(date: .abbreviated, time: .shortened))
                    }
                    if s.backfillDays > 0 {
                        if let earliest = s.backfillEarliest {
                            LabeledContent("過去の分", value: "\(earliest.formatted(date: .abbreviated, time: .omitted))〜")
                        }
                        LabeledContent("日時をつけたビット", value: s.backfillBits.formatted())
                    }
                } else {
                    Text("まだ記録がありません").foregroundStyle(.secondary)
                }
                Button("今すぐ確認") { history.recordNow() }
                    .disabled(!history.isEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

extension HistoryModel {
    /// 埋め合わせには記録開始の全量が要る。
    var canBackfill: Bool { summary?.baselineAt != nil && !isBackfilling }
}

/// 取り込むファイルを選ばせる。選んだファイルはアプリのフォルダにコピーされる。
@MainActor
func chooseImportFiles(into history: HistoryModel) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.json, UTType(filenameExtension: "gpx") ?? .xml]
    panel.message = "GPX か Google マップのタイムライン（JSON）を選んでください"
    guard panel.runModal() == .OK else { return }
    history.addImportFiles(panel.urls)
}
