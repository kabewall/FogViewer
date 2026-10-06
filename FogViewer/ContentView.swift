import MapKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: FogStore
    @StateObject private var map = MapController()
    @StateObject private var search = SearchModel()
    @EnvironmentObject private var history: HistoryModel
    @StateObject private var timelapse = TimelapseModel()
    @StateObject private var regions = RegionModel()

    @AppStorage("mapStyle") private var style: BaseMapStyle = .explore
    @AppStorage("terrain3D") private var terrain3D = false
    @AppStorage("fogEnabled") private var fogEnabled = true
    @AppStorage("fogDensity") private var density: FogDensity = .medium
    @AppStorage("fogColor") private var fogColor: FogColor = .navy
    @AppStorage("fogLineWidth") private var lineWidth: FogLineWidth = .medium
    @State private var hasFramedData = false
    @State private var showsRegions = false

    var body: some View {
        NavigationStack {
            // タイムラプス中は再生位置の霧を描く（番号は通常時と重ならないよう負にする）
            FogMapView(fog: timelapse.isActive ? timelapse.fog : store.fog,
                       generation: timelapse.isActive ? -(timelapse.generation + 1) : store.generation,
                       changed: timelapse.isActive
                           ? timelapse.changedRect.map { (since: -timelapse.generation, rect: $0) } : nil,
                       style: style, terrain3D: terrain3D,
                       fogEnabled: fogEnabled, density: density, color: fogColor, lineWidth: lineWidth,
                       highlight: showsRegions ? regions.highlight : nil, controller: map)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    if timelapse.isActive { TimelapseDateBanner(timelapse: timelapse) } else { statusBanner }
                }
                .overlay(alignment: .topLeading) {
                    if !timelapse.isActive, let item = map.selectedItem {
                        SelectedPlaceCard(item: item, map: map)
                    }
                }
                .overlay(alignment: .bottom) {
                    if timelapse.isActive { TimelapseControls(timelapse: timelapse) }
                }
                .inspector(isPresented: $showsRegions) {
                    RegionRankingView(model: regions, map: map)
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
                .searchable(text: $search.query, placement: .toolbar, prompt: "マップで検索")
                .searchSuggestions {
                    ForEach(search.completions, id: \.self) { completion in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .searchCompletion(SearchModel.key(completion))
                    }
                }
                // 候補を選ぶと検索欄がその候補の文字列になるので、そこで場所を引く
                .onChange(of: search.query) { search.selectIfCompletion(map: map) }
                .onSubmit(of: .search) { search.searchFirst(map: map) }
        }
        .toolbar { toolbar }
        .focusedSceneObject(map)
        .onAppear {
            store.reload()
            history.refresh()
            timelapse.map = map
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
            history.refresh()
        }
        .onChange(of: store.generation) {
            updateRegions()
            // 初回だけ記録のある範囲へ移動する。以降は見ている場所を保つ。
            guard !hasFramedData, let rect = store.visitedMapRect else { return }
            hasFramedData = true
            map.show(rect: rect, animated: false)
        }
        .onChange(of: showsRegions) { showsRegions ? updateRegions() : regions.close() }
    }

    /// 地域ランキングを開いているときだけ集計する（境界の判定に数秒かかるため）。
    private func updateRegions() {
        guard showsRegions else { return }
        regions.update(fog: store.fog, generation: store.generation)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { timelapse.isActive ? timelapse.close() : timelapse.open() } label: {
                Label("タイムラプス", systemImage: timelapse.isActive ? "stop.circle" : "play.circle")
            }
            .help(timelapse.isActive ? "タイムラプスを終わる" : "霧が晴れていく様子を再生")
            .disabled(timelapse.isLoading)
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button { showsRegions.toggle() } label: {
                Label("地域ランキング", systemImage: "list.number")
            }
            .help(showsRegions ? "地域ランキングを閉じる" : "国・都道府県・市区町村ごとの探索面積")
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button { map.showUserLocation() } label: {
                Label("現在地", systemImage: "location")
            }
            .help("現在地を表示")

            Button { if let rect = store.visitedMapRect { map.show(rect: rect) } } label: {
                Label("記録全体を表示", systemImage: "map")
            }
            .help("記録のある範囲を表示")
            .disabled(store.visitedMapRect == nil)

            Button { fogEnabled.toggle() } label: {
                Label("霧", systemImage: fogEnabled ? "cloud.fog.fill" : "cloud.fog")
            }
            .help(fogEnabled ? "霧を隠す" : "霧を表示")
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Menu {
                Picker("地図の種類", selection: $style) {
                    ForEach(BaseMapStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("立体表示（重い）", isOn: $terrain3D)
                Group {
                    Picker("霧の濃さ", selection: $density) {
                        ForEach(FogDensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("霧の色", selection: $fogColor) {
                        ForEach(FogColor.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("晴れた部分の最小の太さ", selection: $lineWidth) {
                        ForEach(FogLineWidth.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                .disabled(!fogEnabled)
            } label: {
                Label("表示", systemImage: "circle.lefthalf.filled")
            }
            .help("地図の種類と、霧の濃さ・色・晴れた部分の太さ")
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = timelapse.errorMessage {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
        } else if timelapse.isLoading {
            ProgressView("履歴を読み込み中…")
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
        } else if let message = store.errorMessage {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
        } else if store.isLoading && store.generation == 0 {
            ProgressView("iCloud から記録を読み込み中…")
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
        } else if !store.failedFiles.isEmpty || history.needsReinstall {
            // 気づいてほしい知らせだけ地図の上に出す。詳しい内容と対処は設定の側にある。
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(history.needsReinstall ? "見張り役は別の場所のアプリを使っています"
                                            : "読めなかったファイルが \(store.failedFiles.count) 件あります")
                SettingsLink { Text("設定を開く") }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
        }
    }
}

/// 検索で選んだ場所。地図の左上に浮かべる。
private struct SelectedPlaceCard: View {
    let item: MKMapItem
    @ObservedObject var map: MapController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.circle.fill").foregroundStyle(.red).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "場所").lineLimit(1)
                if let address = item.placemark.title {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Button { map.clearSelection() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("選択をやめる")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(12)
    }
}

/// タイムラプス中に地図の上に出す日付と探索面積。
private struct TimelapseDateBanner: View {
    @ObservedObject var timelapse: TimelapseModel

    var body: some View {
        VStack(spacing: 2) {
            Text(timelapse.currentTime.formatted(.dateTime.year().month().day()))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(String(format: "探索 %.1f km²", timelapse.areaKm2))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 12)
    }
}

/// タイムラプスの操作バー（地図の下に浮かべる）。
private struct TimelapseControls: View {
    @ObservedObject var timelapse: TimelapseModel

    var body: some View {
        HStack(spacing: 14) {
            Button { timelapse.togglePlay() } label: {
                Image(systemName: timelapse.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .help(timelapse.isPlaying ? "一時停止" : "再生")

            Text(timelapse.start.formatted(.dateTime.year().month()))
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { timelapse.currentTime.timeIntervalSince1970 },
                set: { timelapse.seek(to: Date(timeIntervalSince1970: $0)) }
            ), in: timelapse.start.timeIntervalSince1970...max(timelapse.end.timeIntervalSince1970, timelapse.start.timeIntervalSince1970 + 1))
            .frame(minWidth: 220)
            Text(timelapse.end.formatted(.dateTime.year().month()))
                .font(.caption).foregroundStyle(.secondary)

            Menu {
                Picker("速さ", selection: $timelapse.speed) {
                    ForEach(TimelapseModel.Speed.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("変化のない期間を飛ばす", isOn: $timelapse.skipIdle)
                Toggle("新しく晴れた場所を追う", isOn: $timelapse.follow)
            } label: {
                Label(timelapse.speed.title, systemImage: "speedometer")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button { timelapse.follow.toggle() } label: {
                Image(systemName: timelapse.follow ? "location.fill" : "location")
            }
            .buttonStyle(.plain)
            .help("新しく晴れた場所を追う")

            Button { timelapse.close() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("タイムラプスを終わる")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

/// 場所検索。入力中は MKLocalSearchCompleter の候補、確定したら MKLocalSearch で場所を引く。
@MainActor
final class SearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { completer.queryFragment = query }
    }
    @Published private(set) var completions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func select(_ completion: MKLocalSearchCompletion, map: MapController) {
        run(MKLocalSearch.Request(completion: completion), map: map)
    }

    /// 検索欄の候補として出す文字列。選ばれた候補を見分けるのにも使う。
    static func key(_ completion: MKLocalSearchCompletion) -> String {
        completion.subtitle.isEmpty ? completion.title : "\(completion.title)、\(completion.subtitle)"
    }

    /// 検索欄の文字列が候補のどれかと一致したら（候補が選ばれたら）その場所を引く。
    func selectIfCompletion(map: MapController) {
        guard !query.isEmpty, let completion = completions.first(where: { Self.key($0) == query }) else { return }
        select(completion, map: map)
    }

    func searchFirst(map: MapController) {
        if let first = completions.first(where: { Self.key($0) == query }) ?? completions.first {
            select(first, map: map)
        } else {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            run(request, map: map)
        }
    }

    private func run(_ request: MKLocalSearch.Request, map: MapController) {
        if let region = map.mapView?.region { request.region = region }
        MKLocalSearch(request: request).start { [weak self] response, _ in
            guard let item = response?.mapItems.first else { return }
            Task { @MainActor in
                map.show(item: item)
                self?.query = ""
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.completions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.completions = [] }
    }
}
