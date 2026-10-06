import Foundation

/// 地域ごとの探索面積。親（国・都道府県・政令指定都市）は子の分を含めた合計を持つ。
struct RegionStats {
    struct Entry {
        var bits = 0
        var areaKm2 = 0.0
        /// 子孫の市区町村のうち、1 ビットでも晴れているものの数。
        var visitedMunicipalities = 0
        /// 晴れているビットの範囲（地図をそこへ寄せるのに使う）。
        var visitedBounds = BitRect.null
    }

    let entries: [Entry]
    /// どの地域にも入らなかった分（海上など）。
    let unassigned: Entry
    let totalAreaKm2: Double

    func entry(_ index: Int) -> Entry { entries[index] }

    /// その地域に直接数えた分（子に振り分けられなかった分）。日本なら、どの市区町村にも入らなかったビット。
    func ownAreaKm2(_ index: Int, catalog: RegionCatalog) -> Double {
        entries[index].areaKm2 - catalog.children[index].reduce(0) { $0 + entries[$1].areaKm2 }
    }

    /// 探索率（地域の面積のうち晴れた割合）。
    func rate(_ index: Int, catalog: RegionCatalog) -> Double {
        let area = catalog.regions[index].areaKm2
        return area > 0 ? entries[index].areaKm2 / area : 0
    }

    /// ブロックごとの判定結果。ビットマップが同じブロックは、次の集計で判定し直さずに使う。
    typealias Classified = [UInt32: (bitmap: [UInt8], counts: [Int?: Int])]

    static func compute(fog: FogData, catalog: RegionCatalog) -> RegionStats {
        compute(fog: fog, catalog: catalog, reusing: [:]).stats
    }

    /// 境界の判定はブロックごとに数ミリ秒かかるので、前回の判定結果 `previous` から変わっていないブロックは使い回す。
    static func compute(fog: FogData, catalog: RegionCatalog,
                        reusing previous: Classified) -> (stats: RegionStats, classified: Classified) {
        var classified: Classified = [:]
        classified.reserveCapacity(fog.blocks.count)
        var own = [Entry](repeating: Entry(), count: catalog.regions.count)
        var unassigned = Entry()
        var total = 0.0
        for (key, block) in fog.blocks {
            let bx = Int(key >> 16), by = Int(key & 0xFFFF)
            let bitArea = FogData.bitAreaKm2(blockY: by)
            let rect = BitRect(minX: Double(bx * 64), minY: Double(by * 64), maxX: Double(bx * 64 + 64), maxY: Double(by * 64 + 64))
            let counts: [Int?: Int]
            if let old = previous[key], old.bitmap == block.bitmap {
                counts = old.counts
            } else {
                counts = catalog.classify(blockX: bx, blockY: by, bitmap: block.bitmap)
            }
            // 今の霧のビットマップを持つ（前の霧のビットマップを残さない）
            classified[key] = (block.bitmap, counts)
            for (region, count) in counts {
                let area = Double(count) * bitArea
                total += area
                if let region {
                    own[region].bits += count
                    own[region].areaKm2 += area
                    own[region].visitedBounds = own[region].visitedBounds.union(rect)
                } else {
                    unassigned.bits += count
                    unassigned.areaKm2 += area
                }
            }
        }
        // 子から親へ足し上げる
        var entries = own
        for (i, region) in catalog.regions.enumerated() where own[i].bits > 0 {
            if region.level == .municipality { entries[i].visitedMunicipalities = 1 }
            var p = region.parent
            while let q = p {
                entries[q].bits += own[i].bits
                entries[q].areaKm2 += own[i].areaKm2
                entries[q].visitedBounds = entries[q].visitedBounds.union(own[i].visitedBounds)
                if region.level == .municipality { entries[q].visitedMunicipalities += 1 }
                p = catalog.regions[q].parent
            }
        }
        return (RegionStats(entries: entries, unassigned: unassigned, totalAreaKm2: total), classified)
    }
}
