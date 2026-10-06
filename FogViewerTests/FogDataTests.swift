import XCTest
@testable import FogViewer

final class FogDataTests: XCTestCase {
    func testTileIDFromFilename() {
        // ファイル名の規則：MD5 4 文字 + 数字ごとのマスク + 末尾 2 文字。
        // 東京駅を含むタイルのファイル名。"lowwkk" → 1,0,3,3,6,6。先頭 "3fd0" は md5("103366") の先頭 4 文字。
        // 末尾 2 文字はチェック用で解読に使わないので、ここでは仮の値。
        XCTAssertEqual(FowFormat.tileID(fromFilename: "3fd0lowwkkxx"), 103_366)
        XCTAssertNil(FowFormat.tileID(fromFilename: "abc"))
        XCTAssertNil(FowFormat.tileID(fromFilename: "0000zzzzzzzz"))
    }

    func testParseSyntheticTile() throws {
        // ブロック (3, 5) に 1 ブロックだけ持つタイルを組み立てる。
        var raw = [UInt8](repeating: 0, count: FowFormat.tileHeaderSize + FowFormat.blockSize)
        let headerIndex = 3 + 5 * FowFormat.tileWidth
        raw[headerIndex * 2] = 1
        var bitmap = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)
        bitmap[0] = 0b1000_0000      // (0, 0)
        bitmap[8 * 10 + 1] = 0b0000_0001 // (15, 10)
        raw.replaceSubrange(FowFormat.tileHeaderSize..<(FowFormat.tileHeaderSize + 512), with: bitmap)

        let deflated = try (Data(raw) as NSData).compressed(using: .zlib) as Data
        let zlib = Data([0x78, 0x9C]) + deflated  // 実ファイルと同じく zlib ヘッダ付きにする

        var blocks: [UInt32: FogBlock] = [:]
        // 中央部 "l" → タイル ID 1（末尾 2 文字はチェック用なので解読に使わない）
        try FogParser.parseTile(filename: "abcdlxx", data: zlib, into: &blocks)
        // ID 1 → tileX 1, tileY 0
        let bx = 1 * FowFormat.tileWidth + 3, by = 5
        let block = try XCTUnwrap(blocks[FogData.blockKey(bx, by)])
        XCTAssertTrue(block.isVisited(0, 0))
        XCTAssertTrue(block.isVisited(15, 10))
        XCTAssertFalse(block.isVisited(1, 0))
        XCTAssertEqual(block.visitedCount, 2)
    }

    func testRealSyncFolderIfPresent() throws {
        let folder = FogStore.syncFolder
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path), "iCloud データなし")
        let result = FogParser.load(syncFolder: folder)
        XCTAssertGreaterThan(result.data.blocks.count, 0)
        XCTAssertTrue(result.failures.isEmpty, "読めなかった: \(result.failures)")
    }
}

final class FogRasterTests: XCTestCase {
    /// ブロック (0, 0) のビット (0, 0) と (63, 63) だけ訪問済みのデータ。
    private func cornerFog() -> FogData {
        var bitmap = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)
        bitmap[0] = 0b1000_0000
        bitmap[63 * 8 + 7] = 0b0000_0001
        return FogData(blocks: [FogData.blockKey(0, 0): FogBlock(bitmap: bitmap)])
    }

    func testOneBitPerPixel() {
        let fog = cornerFog()
        let blocks = FogRaster.blocks(in: fog, bitX0: 0, bitY0: 0, bitX1: 64, bitY1: 64)
        let px = FogRaster.rgba(fog: fog, blocks: blocks, originX: 0, originY: 0,
                                bitsPerPixelLog2: 0, width: 64, height: 64, opacity: 0.5)
        XCTAssertEqual(px[0], 0)                 // 左上は透明
        XCTAssertEqual(px[63 * 64 + 63], 0)      // 右下は透明
        XCTAssertNotEqual(px[1], 0)              // 隣は霧
        XCTAssertEqual(px.filter { $0 == 0 }.count, 2)
    }

    func testZoomedInScalesBits() {
        let fog = cornerFog()
        let blocks = FogRaster.blocks(in: fog, bitX0: 0, bitY0: 0, bitX1: 2, bitY1: 2)
        // 1 ビット = 4×4 ピクセル。範囲 2×2 ビット → 8×8 ピクセル。
        // ビット (0, 0) は中心 (2, 2)・直径 6 の円で抜かれ、正方形より少し外まで晴れる。
        let px = FogRaster.rgba(fog: fog, blocks: blocks, originX: 0, originY: 0,
                                bitsPerPixelLog2: -2, width: 8, height: 8, opacity: 0.5)
        XCTAssertTrue((18...30).contains(px.filter { $0 == 0 }.count))
        XCTAssertEqual(px[3 * 8 + 3], 0)
        XCTAssertEqual(px[2 * 8 + 4], 0)          // 正方形の外側
        XCTAssertNotEqual(px[6 * 8 + 6], 0)       // 円の外は霧
    }

    func testZoomedOutKeepsBlockVisible() {
        let fog = cornerFog()
        // 1 ピクセル = 256 ビット。ブロックは 1 ピクセルに縮むが消えない。
        let blocks = FogRaster.blocks(in: fog, bitX0: 0, bitY0: 0, bitX1: 1024, bitY1: 1024)
        let px = FogRaster.rgba(fog: fog, blocks: blocks, originX: 0, originY: 0,
                                bitsPerPixelLog2: 8, width: 4, height: 4, opacity: 0.5)
        XCTAssertEqual(px[0], 0)
        XCTAssertEqual(px.filter { $0 == 0 }.count, 1)
    }

    func testPixelBitConversions() {
        XCTAssertEqual(FogRaster.pixels(100, 2), 25)
        XCTAssertEqual(FogRaster.pixels(101, 2), 26)
        XCTAssertEqual(FogRaster.pixels(10, -3), 80)
        XCTAssertEqual(FogRaster.bits(26, 2), 104)
        XCTAssertEqual(FogRaster.bits(80, -3), 10)
    }
}

final class FogLineWidthTests: XCTestCase {
    /// ブロック (1, 1) の中央のビット (32, 32) だけ訪問済みのデータ。
    private func singleBitFog() -> (FogData, x: Int, y: Int) {
        var bitmap = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)
        bitmap[32 * 8 + 4] = 0b1000_0000
        return (FogData(blocks: [FogData.blockKey(1, 1): FogBlock(bitmap: bitmap)]), 64 + 32, 64 + 32)
    }

    private func clearedCount(_ px: [UInt32]) -> Int { px.filter { $0 == 0 }.count }

    func testMinDiameterWidensSingleBit() {
        let (fog, gx, gy) = singleBitFog()
        let blocks = FogRaster.blocks(in: fog, bitX0: 0, bitY0: 0, bitX1: 256, bitY1: 256)
        let thin = FogRaster.rgba(fog: fog, blocks: blocks, originX: 0, originY: 0,
                                  bitsPerPixelLog2: 0, width: 256, height: 256, minDiameter: 0, opacity: 0.5)
        XCTAssertEqual(clearedCount(thin), 1)

        let wide = FogRaster.rgba(fog: fog, blocks: blocks, originX: 0, originY: 0,
                                  bitsPerPixelLog2: 0, width: 256, height: 256, minDiameter: 7, opacity: 0.5)
        // 直径 7 の円はおよそ π×3.5² ≈ 38 ピクセル。
        XCTAssertTrue((30...45).contains(clearedCount(wide)), "\(clearedCount(wide))")
        // 円の中心は元のビット。
        XCTAssertEqual(wide[gy * 256 + gx], 0)
        XCTAssertEqual(wide[gy * 256 + gx + 3], 0)
        XCTAssertEqual(wide[(gy + 3) * 256 + gx], 0)
        XCTAssertNotEqual(wide[gy * 256 + gx + 5], 0)
    }

    func testZoomedInBitIsCircle() {
        // 1 ビット = 8 ピクセル。最小 4 ピクセルより大きいが、角を丸めるため直径 12 の円で抜く。
        let (fog, gx, gy) = singleBitFog()
        let m = FogRaster.marginBits(minDiameter: 4, bitsPerPixelLog2: -3)
        let blocks = FogRaster.blocks(in: fog, bitX0: gx - 4 - m, bitY0: gy - 4 - m, bitX1: gx + 4 + m, bitY1: gy + 4 + m)
        let px = FogRaster.rgba(fog: fog, blocks: blocks, originX: gx - 4, originY: gy - 4,
                                bitsPerPixelLog2: -3, width: 64, height: 64, minDiameter: 4, opacity: 0.5)
        // ビットの正方形は (32..<40, 32..<40)。円はその中心 (36, 36) を中心に半径 6。
        XCTAssertTrue((100...125).contains(clearedCount(px)), "\(clearedCount(px))")  // π×6² ≈ 113
        XCTAssertEqual(px[36 * 64 + 36], 0)
        XCTAssertEqual(px[36 * 64 + 31], 0)       // 正方形の外側にもはみ出す
        XCTAssertNotEqual(px[30 * 64 + 30], 0)
    }

    func testSmallCellsStaySquare() {
        // 1 ビット = 2 ピクセル。小さいセルは円にしない。
        XCTAssertEqual(FogRaster.stampDiameter(minDiameter: 0, bitsPerPixelLog2: -1), 2)
        XCTAssertEqual(FogRaster.stampDiameter(minDiameter: 0, bitsPerPixelLog2: 0), 1)
        XCTAssertEqual(FogRaster.stampDiameter(minDiameter: 6, bitsPerPixelLog2: 2), 6)
        XCTAssertEqual(FogRaster.stampDiameter(minDiameter: 6, bitsPerPixelLog2: -4), 24)
    }

    func testCircleFromNeighborRangeReachesEdge() {
        // 記録は描画範囲のすぐ左外（1 ピクセル外）。太らせた円が範囲の左端にはみ出してくること。
        let (fog, gx, gy) = singleBitFog()
        let originX = gx + 1
        let margin = FogRaster.marginBits(minDiameter: 7, bitsPerPixelLog2: 0)
        let blocks = FogRaster.blocks(in: fog, bitX0: originX - margin, bitY0: 0 - margin,
                                      bitX1: originX + 64 + margin, bitY1: 256 + margin)
        let px = FogRaster.rgba(fog: fog, blocks: blocks, originX: originX, originY: 0,
                                bitsPerPixelLog2: 0, width: 64, height: 256, minDiameter: 7, opacity: 0.5)
        XCTAssertEqual(px[gy * 64 + 0], 0)
        XCTAssertEqual(px[gy * 64 + 1], 0)
        XCTAssertNotEqual(px[gy * 64 + 4], 0)
    }
}
