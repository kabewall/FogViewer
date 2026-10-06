import Foundation

/// ブロック 1 つ分（64×64）のビット集合を BLOB にする。
///
/// - 先頭 0x00: 立っているビットの位置を UInt16（上位 6 ビット = y, 下位 6 ビット = x、リトルエンディアン）で並べる。
/// - 先頭 0x01: 512 バイトのビットマップをそのまま続ける。
/// ビットが少ない（平均 20 ビット弱）ので、たいていは前者の方が圧縮より小さい。
enum DiffCodec {
    static let sparseTag: UInt8 = 0
    static let bitmapTag: UInt8 = 1
    /// 位置の並びの方が小さくなる最大ビット数（2 バイト × 255 = 510 < 512）。
    static let maxSparseBits = 255

    static func encode(_ bitmap: [UInt8]) -> Data? {
        precondition(bitmap.count == FowFormat.blockBitmapSize)
        let count = bitmap.reduce(0) { $0 + $1.nonzeroBitCount }
        guard count > 0 else { return nil }
        if count > maxSparseBits {
            return Data([bitmapTag]) + Data(bitmap)
        }
        var out = Data(capacity: 1 + count * 2)
        out.append(sparseTag)
        for (i, byte) in bitmap.enumerated() where byte != 0 {
            let y = i / 8, xBase = (i % 8) * 8
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                let v = UInt16(y) << 6 | UInt16(xBase + bit)
                out.append(UInt8(v & 0xFF))
                out.append(UInt8(v >> 8))
            }
        }
        return out
    }

    static func decode(_ data: Data) -> [UInt8]? {
        guard let tag = data.first else { return nil }
        let body = data.dropFirst()
        switch tag {
        case bitmapTag:
            guard body.count == FowFormat.blockBitmapSize else { return nil }
            return [UInt8](body)
        case sparseTag:
            guard body.count % 2 == 0 else { return nil }
            var bitmap = [UInt8](repeating: 0, count: FowFormat.blockBitmapSize)
            var it = body.makeIterator()
            while let lo = it.next(), let hi = it.next() {
                let v = Int(lo) | Int(hi) << 8
                let x = v & 0x3F, y = (v >> 6) & 0x3F
                bitmap[y * 8 + x / 8] |= 0x80 >> UInt8(x % 8)
            }
            return bitmap
        default:
            return nil
        }
    }

    /// `new` にあって `old` にないビット。
    static func subtract(_ new: [UInt8], _ old: [UInt8]?) -> [UInt8] {
        guard let old else { return new }
        return zip(new, old).map { $0 & ~$1 }
    }

    static func bitCount(_ bitmap: [UInt8]) -> Int {
        bitmap.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}
