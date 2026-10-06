import Foundation

/// Fog of World の Sync タイル形式の読み込み。
///
/// 世界全体は Web メルカトル上で 512×512 タイル、
/// 1 タイルは 128×128 ブロック、1 ブロックは 64×64 ビット。
/// つまり世界の幅は 2^22 ビット（赤道で 1 ビット ≒ 9.55 m）。
enum FowFormat {
    static let mapWidth = 512
    static let tileWidth = 128
    static let bitmapWidth = 64
    static let blockBitmapSize = 512
    static let blockSize = blockBitmapSize + 3
    static let tileHeaderSize = tileWidth * tileWidth * 2
    /// 世界の幅（ビット数）の log2。
    static let worldBitsLog2 = 22
    /// 世界の幅（ブロック数）。
    static let worldBlocks = mapWidth * tileWidth

    private static let filenameMask = Array("olhwjsktri")

    /// ファイル名からタイル ID を取り出す。先頭 4 文字は MD5、末尾 2 文字はチェック用。
    static func tileID(fromFilename name: String) -> Int? {
        let chars = Array(name)
        guard chars.count > 6 else { return nil }
        var id = 0
        for c in chars[4..<(chars.count - 2)] {
            guard let digit = filenameMask.firstIndex(of: c) else { return nil }
            id = id * 10 + digit
        }
        return id
    }
}

/// 1 ブロック分（64×64 ビット）の訪問ビットマップ。
struct FogBlock {
    /// 512 バイト。行優先、各バイトの最上位ビットが左端。
    let bitmap: [UInt8]

    func isVisited(_ x: Int, _ y: Int) -> Bool {
        bitmap[x / 8 + y * 8] & (UInt8(0x80) >> UInt8(x % 8)) != 0
    }

    /// 晴れたビットごとに、ブロックの中での位置（x, y は 0..<64）を渡す。
    func forEachVisited(_ body: (_ x: Int, _ y: Int) -> Void) {
        for (i, byte) in bitmap.enumerated() where byte != 0 {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 { body((i % 8) * 8 + bit, i / 8) }
        }
    }

    var visitedCount: Int {
        bitmap.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}

/// 読み込んだ全データ。ブロックを世界座標（ブロック単位）で保持する不変値。
struct FogData {
    /// キーは `blockKey(bx, by)`。
    let blocks: [UInt32: FogBlock]
    /// 範囲検索用にブロック座標だけを並べたもの。
    let blockCoords: [(x: Int, y: Int)]

    static let empty = FogData(blocks: [:])

    init(blocks: [UInt32: FogBlock]) {
        self.blocks = blocks
        self.blockCoords = blocks.keys.map { (Int($0 >> 16), Int($0 & 0xFFFF)) }
    }

    static func blockKey(_ bx: Int, _ by: Int) -> UInt32 {
        UInt32(bx) << 16 | UInt32(by)
    }

    func block(_ bx: Int, _ by: Int) -> FogBlock? {
        blocks[Self.blockKey(bx, by)]
    }

    /// 訪問済みの範囲（ブロック単位、半開区間）。データがなければ nil。
    var blockBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard let first = blockCoords.first else { return nil }
        var b = (minX: first.x, minY: first.y, maxX: first.x + 1, maxY: first.y + 1)
        for c in blockCoords {
            b.minX = min(b.minX, c.x); b.minY = min(b.minY, c.y)
            b.maxX = max(b.maxX, c.x + 1); b.maxY = max(b.maxY, c.y + 1)
        }
        return b
    }

    /// 探索済み面積（km²）。ビットの大きさは緯度で変わるのでブロックごとに補正する。
    var exploredAreaKm2: Double {
        blocks.reduce(0) { $0 + Double($1.value.visitedCount) * Self.bitAreaKm2(blockY: Int($1.key & 0xFFFF)) }
    }

    /// その行のブロックの 1 ビットの面積（km²）。ブロックの中心の緯度で補正する。
    static func bitAreaKm2(blockY by: Int) -> Double {
        let equatorBitKm = 40_075.016686 / Double(1 << FowFormat.worldBitsLog2)
        let side = equatorBitKm * cos(latitude(ofBlockY: Double(by) + 0.5) * .pi / 180)
        return side * side
    }

    static func latitude(ofBlockY by: Double) -> Double {
        let n = Double.pi - 2 * Double.pi * by / Double(FowFormat.worldBlocks)
        return atan(sinh(n)) * 180 / .pi
    }
}

enum FogParseError: Error {
    case badFilename(String)
    case decompressFailed(String)
    case truncated(String)
}

enum FogParser {
    /// タイルファイル 1 つを読み、含まれるブロックを `into` に追加する。
    static func parseTile(filename: String, data: Data, into blocks: inout [UInt32: FogBlock]) throws {
        guard let id = FowFormat.tileID(fromFilename: filename) else {
            throw FogParseError.badFilename(filename)
        }
        let tileX = id % FowFormat.mapWidth
        let tileY = id / FowFormat.mapWidth

        // 中身は zlib。Apple の .zlib は生 deflate なので 2 バイトのヘッダを飛ばす。
        guard data.count > 2,
              let raw = try? (data.dropFirst(2) as NSData).decompressed(using: .zlib) as Data
        else { throw FogParseError.decompressFailed(filename) }
        let bytes = [UInt8](raw)
        guard bytes.count >= FowFormat.tileHeaderSize else { throw FogParseError.truncated(filename) }

        for i in 0..<(FowFormat.tileWidth * FowFormat.tileWidth) {
            let blockIdx = Int(bytes[i * 2]) | Int(bytes[i * 2 + 1]) << 8
            guard blockIdx > 0 else { continue }
            let start = FowFormat.tileHeaderSize + (blockIdx - 1) * FowFormat.blockSize
            guard start + FowFormat.blockBitmapSize <= bytes.count else { throw FogParseError.truncated(filename) }
            let block = FogBlock(bitmap: Array(bytes[start..<(start + FowFormat.blockBitmapSize)]))
            let bx = tileX * FowFormat.tileWidth + i % FowFormat.tileWidth
            let by = tileY * FowFormat.tileWidth + i / FowFormat.tileWidth
            blocks[FogData.blockKey(bx, by)] = block
        }
    }

    /// Sync フォルダ内の全タイルを読む。読めなかったファイル名も返す。
    /// iCloud 上でまだダウンロードされていないファイルは、ファイル協調読み込みで取得させる。
    static func load(syncFolder: URL) -> (data: FogData, failures: [String]) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: syncFolder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        var blocks: [UInt32: FogBlock] = [:]
        var failures: [String] = []
        let coordinator = NSFileCoordinator()
        for name in names {
            let url = syncFolder.appendingPathComponent(name)
            var fileData: Data?
            var coordError: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                fileData = try? Data(contentsOf: readURL)
            }
            guard let fileData, !fileData.isEmpty else {
                failures.append(name)
                continue
            }
            do {
                try parseTile(filename: name, data: fileData, into: &blocks)
            } catch {
                failures.append(name)
            }
        }
        return (FogData(blocks: blocks), failures)
    }
}
