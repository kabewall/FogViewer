import XCTest
@testable import FogViewer

final class FogRenderBenchmark: XCTestCase {
    func testRenderTiming() throws {
        let folder = FogStore.syncFolder
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path))
        var t = Date()
        let fog = FogParser.load(syncFolder: folder).data
        print("BENCH load: \(Int(Date().timeIntervalSince(t) * 1000)) ms, blocks \(fog.blocks.count)")
        // 訪問ビットが最も多いブロックの位置を中心に、各ズームで描く
        guard let dense = fog.blocks.max(by: { $0.value.visitedCount < $1.value.visitedCount }) else { return }
        let cx = Int(dense.key >> 16) * FowFormat.bitmapWidth + 32
        let cy = Int(dense.key & 0xFFFF) * FowFormat.bitmapWidth + 32
        for diameter in [0, 6] {
        for z in [3, 6, 9, 12, 14, 16, 18] {
            // MapKit の描画単位に近い 512 ピクセル四方（Retina の 256pt タイル）を 9 枚描く。
            let bppLog2 = FowFormat.worldBitsLog2 - z - 9
            let tileLog2 = FowFormat.worldBitsLog2 - z
            let span = 1 << tileLog2
            let x0 = (cx >> tileLog2) << tileLog2, y0 = (cy >> tileLog2) << tileLog2
            t = Date()
            var cleared = 0
            for dy in -1...1 { for dx in -1...1 {
                let ox = x0 + dx * span, oy = y0 + dy * span
                let m = FogRaster.marginBits(minDiameter: diameter, bitsPerPixelLog2: bppLog2)
                let targets = FogRaster.blocks(in: fog, bitX0: ox - m, bitY0: oy - m, bitX1: ox + span + m, bitY1: oy + span + m)
                let px = FogRaster.rgba(fog: fog, blocks: targets, originX: ox, originY: oy,
                                        bitsPerPixelLog2: bppLog2, width: 512, height: 512,
                                        minDiameter: diameter, opacity: 0.65)
                cleared += px.lazy.filter { $0 == 0 }.count
            }}
            print("BENCH d\(diameter) z\(z): \(Int(Date().timeIntervalSince(t) * 1000 / 9)) ms/tile, cleared px \(cleared / 9)")
        }
        }
    }
}

final class TimelapseBenchmark: XCTestCase {
    func testTimelapseTiming() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: HistoryStore.defaultURL.path))
        var t = Date()
        let data = try TimelapseData.load(from: try HistoryStore(readOnly: true))
        print("BENCH timelapse load: \(Int(Date().timeIntervalSince(t) * 1000)) ms, steps \(data.steps.count), first \(data.start!), last \(data.end!)")
        var cursor = TimelapseCursor(data: data)
        t = Date()
        cursor.move(to: data.end!)
        print("BENCH apply all: \(Int(Date().timeIntervalSince(t) * 1000)) ms, bits \(cursor.visibleBits), area \(Int(cursor.areaKm2)) km²")
        t = Date()
        let fog = cursor.fogData
        print("BENCH fogData at end: \(Int(Date().timeIntervalSince(t) * 1000)) ms, blocks \(fog.blocks.count)")
        t = Date()
        cursor.move(to: data.steps[data.steps.count / 2].time)
        print("BENCH seek back to middle: \(Int(Date().timeIntervalSince(t) * 1000)) ms")
    }
}
