import SwiftUI

/// バッジの一覧。種類ごとに、取れたもの・次の段階に近いものから並べる。
struct BadgeListView: View {
    @ObservedObject var model: BadgeModel
    @ObservedObject var map: MapController
    @EnvironmentObject private var store: FogStore
    @State private var showsAllPrefectures = false
    /// 都道府県の欄で、畳んだときに出す数。
    private let prefectureLimit = 8

    var body: some View {
        if !model.badges.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    ForEach(Badge.Category.allCases) { category in
                        let items = sorted.filter { $0.category == category }
                        if !items.isEmpty { section(category, items) }
                    }
                    Text("境界：Natural Earth、「国土数値情報（行政区域データ）」（国土交通省）を加工して作成")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if model.isComputing {
                    ProgressView().controlSize(.small).padding(12).help("新しい記録で判定し直しています")
                }
            }
        } else if let message = model.errorMessage ?? (store.generation == 0 ? store.errorMessage : nil) {
            ContentUnavailableView("判定できません", systemImage: "exclamationmark.triangle", description: Text(message))
        } else if store.generation == 0 {
            ProgressView("記録を読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("バッジを判定中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 並べ方

    /// 段階の高いもの、次の段階に近いものから。
    private var sorted: [Badge] {
        model.badges.sorted {
            $0.level != $1.level ? $0.level > $1.level : Self.progress($0) > Self.progress($1)
        }
    }

    /// 次の段階までの進み具合（0〜1）。すべて取れていれば 1。
    static func progress(_ badge: Badge) -> Double {
        guard let next = badge.next else { return 1 }
        let previous = badge.level > 0 ? badge.tiers[badge.level - 1].threshold : 0
        return min(max((badge.value - previous) / max(next.threshold - previous, 1e-9), 0), 1)
    }

    // MARK: 部品

    private var summary: some View {
        let earned = model.badges.filter { $0.level > 0 }
        return HStack(spacing: 16) {
            ForEach([3, 2, 1], id: \.self) { level in
                VStack(spacing: 2) {
                    Image(systemName: "rosette").font(.title2).foregroundStyle(Self.color(level: level))
                    Text("\(earned.filter { $0.level == level }.count)").font(.title3.weight(.bold)).monospacedDigit()
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("取れたバッジ").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(earned.count)").font(.title.weight(.bold)).monospacedDigit()
                    Text("/\(model.badges.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(14)
        .background(Passport.sea, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(.white)
    }

    private func section(_ category: Badge.Category, _ items: [Badge]) -> some View {
        let folds = category == .prefectureMesh && items.count > prefectureLimit
        return VStack(alignment: .leading, spacing: 8) {
            Text(category.title).font(.headline)
            grid(folds && !showsAllPrefectures ? Array(items.prefix(prefectureLimit)) : items)
            if folds {
                Button(showsAllPrefectures ? "上位 \(prefectureLimit) 件だけ表示" : "すべて表示（\(items.count)）") {
                    showsAllPrefectures.toggle()
                }
                .buttonStyle(.link)
            }
        }
    }

    private func grid(_ items: [Badge]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(items) { badge in
                // 地図に出すものがないバッジも、薄く見えないよう押せるままにして、押しても何もしない
                Button { if badge.target != nil { model.select(badge, map: map) } } label: {
                    BadgeCard(badge: badge, isSelected: model.selectedID == badge.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 段階の色。0 はまだ。
    static func color(level: Int) -> Color {
        switch level {
        case 1: Color(red: 0.80, green: 0.50, blue: 0.25)
        case 2: Color(red: 0.75, green: 0.78, blue: 0.82)
        case 3: Color(red: 0.98, green: 0.80, blue: 0.20)
        default: Color.secondary.opacity(0.5)
        }
    }
}

/// バッジ 1 つ分のカード。
private struct BadgeCard: View {
    let badge: Badge
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle().fill(BadgeListView.color(level: badge.level).opacity(badge.level > 0 ? 1 : 0.25))
                    Image(systemName: badge.symbol).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(badge.level > 0 ? .black.opacity(0.75) : .secondary)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(badge.title).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(valueText).font(.title3.weight(.bold)).monospacedDigit()
                }
            }
            ProgressView(value: BadgeListView.progress(badge))
                .tint(BadgeListView.color(level: badge.level + (badge.next == nil ? 0 : 1)))
            Text(nextText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let detail = badge.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .help(badge.tiers.map { "\($0.name) \(format($0.threshold))" }.joined(separator: "・"))
    }

    private var valueText: String { format(badge.value) }

    private var nextText: String {
        guard let next = badge.next else { return "すべての段階を達成" }
        return "\(next.name)まであと \(format(next.threshold - badge.value))"
    }

    private func format(_ value: Double) -> String {
        badge.unit == "%" ? Passport.number(value, fraction: 1) + "%"
                          : Passport.number(value, fraction: 0) + " " + badge.unit
    }
}
