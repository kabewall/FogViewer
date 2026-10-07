import CoreGraphics
import MapKit

/// 世界全体を覆う霧のオーバーレイ。描画は `FogOverlayRenderer` がその場で行う。
///
/// MKTileOverlay だとズーム時に新しいタイルの非同期読み込みが終わるまで霧が消え、
/// 下の地図が一瞬見えてしまう。MKOverlayRenderer なら描き終わるまで前の描画が残る。
final class FogOverlay: NSObject, MKOverlay {
    /// 霧の中身。タイムラプスでは描き直しのたびに差し替える（描画は別スレッドなのでロックで守る）。
    var fog: FogData {
        get { lock.lock(); defer { lock.unlock() }; return _fog }
        set { lock.lock(); _fog = newValue; lock.unlock() }
    }
    private var _fog: FogData
    private let lock = NSLock()
    let opacity: Double
    let color: FogRGB
    /// 晴れた部分の最小の太さ（画面上のポイント）。0 なら記録のビットをそのまま描く。
    let minLineWidth: Double
    /// 1 ビットを抜く円の直径（ビット数、地図上の大きさ）。ズームに合わせて画面上の大きさが変わる。
    let bitDiameter: Double

    init(fog: FogData, opacity: Double, color: FogRGB, minLineWidth: Double, bitDiameter: Double = 0) {
        self._fog = fog
        self.opacity = opacity
        self.color = color
        self.minLineWidth = minLineWidth
        self.bitDiameter = bitDiameter
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
    func canReplaceMapContent() -> Bool { false }
}

final class FogOverlayRenderer: MKOverlayRenderer {
    private let fogOverlay: FogOverlay
    private let opacity: Double
    private let color: FogRGB
    private let minLineWidth: Double
    private let bitDiameter: Double
    private let backingScale: Double

    init(overlay: FogOverlay, backingScale: Double) {
        self.fogOverlay = overlay
        self.opacity = overlay.opacity
        self.color = overlay.color
        self.minLineWidth = overlay.minLineWidth
        self.bitDiameter = overlay.bitDiameter
        self.backingScale = backingScale
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let fog = fogOverlay.fog
        let rect = self.rect(for: mapRect)
        let fogColor = CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: opacity)

        // 描画範囲をビット単位に直す（MapKit の世界幅 2^28 ÷ 霧の世界幅 2^22 = 64）。
        let mapPointsPerBit = MKMapSize.world.width / Double(1 << FowFormat.worldBitsLog2)
        let bitX0 = Int((mapRect.minX / mapPointsPerBit).rounded(.down))
        let bitY0 = Int((mapRect.minY / mapPointsPerBit).rounded(.down))
        let bitX1 = Int((mapRect.maxX / mapPointsPerBit).rounded(.up))
        let bitY1 = Int((mapRect.maxY / mapPointsPerBit).rounded(.up))

        // 画面の 1 ピクセルあたりのビット数を 2 の累乗に丸める（負なら 1 ビットが複数ピクセル）。
        let pixelsPerBit = mapPointsPerBit * Double(zoomScale) * backingScale
        var bitsPerPixelLog2 = Int((-log2(pixelsPerBit)).rounded())
        // 画像が大きくなりすぎないよう、1 辺 2048 ピクセルに収める。
        while FogRaster.pixels(bitX1 - bitX0, bitsPerPixelLog2) > 2048 { bitsPerPixelLog2 += 1 }

        // 最小の太さを画像のピクセル数に直す（2 の累乗に丸めた分だけ画面のピクセルとずれる）。
        let screenPixelsPerImagePixel = pixelsPerBit * pow(2, Double(bitsPerPixelLog2))
        // 地図上の大きさで決めた円の直径も画像のピクセル数に直し、大きい方を使う。
        let bitDiameterPixels = bitDiameter / pow(2, Double(bitsPerPixelLog2))
        let minDiameter = Int(max(minLineWidth * backingScale / screenPixelsPerImagePixel, bitDiameterPixels).rounded())

        // 原点を 1 ピクセルの境界にそろえる。
        let align = max(bitsPerPixelLog2, 0)
        let originX = (bitX0 >> align) << align
        let originY = (bitY0 >> align) << align
        let width = FogRaster.pixels(bitX1 - originX, bitsPerPixelLog2)
        let height = FogRaster.pixels(bitY1 - originY, bitsPerPixelLog2)

        // 隣の範囲の記録も太らせるとはみ出してくるので、その分広く集める。
        let margin = FogRaster.marginBits(minDiameter: minDiameter, bitsPerPixelLog2: bitsPerPixelLog2)
        let blocks = FogRaster.blocks(in: fog, bitX0: originX - margin, bitY0: originY - margin,
                                      bitX1: bitX1 + margin, bitY1: bitY1 + margin)
        guard !blocks.isEmpty else {
            context.setFillColor(fogColor)
            context.fill(rect)
            return
        }

        guard let image = FogRaster.image(fog: fog, blocks: blocks, originX: originX, originY: originY,
                                          bitsPerPixelLog2: bitsPerPixelLog2, width: width, height: height,
                                          minDiameter: minDiameter, color: color, opacity: opacity)
        else { return }

        // 画像が覆う範囲（原点をそろえた分だけ mapRect より左上に広い）。
        let imageMapRect = MKMapRect(
            origin: MKMapPoint(x: Double(originX) * mapPointsPerBit, y: Double(originY) * mapPointsPerBit),
            size: MKMapSize(width: Double(FogRaster.bits(width, bitsPerPixelLog2)) * mapPointsPerBit,
                            height: Double(FogRaster.bits(height, bitsPerPixelLog2)) * mapPointsPerBit))
        let imageRect = self.rect(for: imageMapRect)

        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .none
        // オーバーレイの座標系は下向きなので、画像を上下反転して描く。
        context.translateBy(x: 0, y: imageRect.maxY + imageRect.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: imageRect)
        context.restoreGState()
    }
}

/// 霧の色（0〜1 の sRGB）。
struct FogRGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double
    static let `default` = FogRGB(r: 0.07, g: 0.11, b: 0.24)
}

/// 霧のラスタライズ。描画範囲をビット座標で受け取り、訪問済みビットだけ透明な画像を作る。
enum FogRaster {

    /// `bits` ビットを表すのに必要なピクセル数。
    static func pixels(_ bits: Int, _ bitsPerPixelLog2: Int) -> Int {
        bitsPerPixelLog2 >= 0
            ? (bits + (1 << bitsPerPixelLog2) - 1) >> bitsPerPixelLog2
            : bits << -bitsPerPixelLog2
    }

    /// `pixels` ピクセルが表すビット数。
    static func bits(_ pixels: Int, _ bitsPerPixelLog2: Int) -> Int {
        bitsPerPixelLog2 >= 0 ? pixels << bitsPerPixelLog2 : pixels >> -bitsPerPixelLog2
    }

    /// ビット範囲 [bitX0, bitX1) × [bitY0, bitY1) に重なる記録ブロックの座標。
    static func blocks(in fog: FogData, bitX0: Int, bitY0: Int, bitX1: Int, bitY1: Int) -> [(x: Int, y: Int)] {
        let bw = FowFormat.bitmapWidth
        let bx0 = max(bitX0, 0) / bw, by0 = max(bitY0, 0) / bw
        let bx1 = (bitX1 - 1) / bw, by1 = (bitY1 - 1) / bw
        guard bx0 <= bx1, by0 <= by1 else { return [] }

        // 範囲が保有ブロック数より広いなら全件走査の方が速い。
        var targets: [(x: Int, y: Int)] = []
        if (bx1 - bx0 + 1) * (by1 - by0 + 1) > fog.blockCoords.count {
            for c in fog.blockCoords where c.x >= bx0 && c.x <= bx1 && c.y >= by0 && c.y <= by1 {
                targets.append(c)
            }
        } else {
            for by in by0...by1 {
                for bx in bx0...bx1 where fog.block(bx, by) != nil {
                    targets.append((bx, by))
                }
            }
        }
        return targets
    }

    /// 拡大時に 1 ビットを描く円の直径（1 ビットの辺に対する倍率）。
    /// 1 より大きくして隣のビットの円と重ね、正方形の並びではなく滑らかな帯に見せる。
    static let bitCircleScale = 1.5

    /// 訪問済みのセル 1 つを抜く図形の直径（ピクセル）。セルより大きければ円、同じなら正方形。
    static func stampDiameter(minDiameter: Int, bitsPerPixelLog2: Int) -> Int {
        let cellPx = 1 << max(-bitsPerPixelLog2, 0)
        // 数ピクセル程度のセルは正方形でも角が目立たないので、そのままにする。
        let circle = cellPx >= 4 ? Int((Double(cellPx) * bitCircleScale).rounded()) : cellPx
        return max(minDiameter, circle)
    }

    /// 図形がセルからはみ出す分、範囲外から届きうる距離（ビット）。
    static func marginBits(minDiameter: Int, bitsPerPixelLog2: Int) -> Int {
        let cellPx = 1 << max(-bitsPerPixelLog2, 0)
        let diameter = stampDiameter(minDiameter: minDiameter, bitsPerPixelLog2: bitsPerPixelLog2)
        guard diameter > cellPx else { return 0 }
        let radius = (diameter + 1) / 2
        return bitsPerPixelLog2 >= 0 ? radius << bitsPerPixelLog2 : (radius >> -bitsPerPixelLog2) + 1
    }

    /// 霧で塗りつぶし、`blocks` の訪問済みビットだけ透明にした RGBA ピクセル列。
    ///
    /// 訪問済みの「セル」（縮小時は 1 ピクセル、拡大時は 1 ビット分の正方形）を集め、
    /// `stampDiameter` の円で抜く（円にする必要がない小さなセルは正方形のまま）。
    static func rgba(fog: FogData, blocks targets: [(x: Int, y: Int)], originX: Int, originY: Int,
                     bitsPerPixelLog2: Int, width: Int, height: Int,
                     minDiameter: Int = 0, color: FogRGB = .default, opacity: Double) -> [UInt32] {
        // RGBA（乗算済みアルファ）をリトルエンディアンの UInt32 1 つで表す。
        let a = UInt32((opacity * 255).rounded())
        let r = UInt32((color.r * opacity * 255).rounded())
        let g = UInt32((color.g * opacity * 255).rounded())
        let b = UInt32((color.b * opacity * 255).rounded())
        var pixels = [UInt32](repeating: r | g << 8 | b << 16 | a << 24, count: width * height)

        let bw = FowFormat.bitmapWidth
        let cellLog2 = max(-bitsPerPixelLog2, 0)   // セル 1 辺のピクセル数の log2
        let cellPx = 1 << cellLog2
        let bitsPerCellLog2 = max(bitsPerPixelLog2, 0)
        let diameter = stampDiameter(minDiameter: minDiameter, bitsPerPixelLog2: bitsPerPixelLog2)
        // 範囲外のセルからでも円が届く分だけ、セルの格子を広げておく。
        let marginCells = diameter > cellPx ? (diameter / 2) / cellPx + 1 : 0
        let gridW = ((width + cellPx - 1) >> cellLog2) + marginCells * 2
        let gridH = ((height + cellPx - 1) >> cellLog2) + marginCells * 2
        var hits = [Bool](repeating: false, count: gridW * gridH)
        var hitList: [Int] = []

        // 1. 訪問済みのセルに印をつける（同じセルに落ちる複数ビットはまとめる）。
        hits.withUnsafeMutableBufferPointer { grid in
            @inline(__always) func mark(_ cx: Int, _ cy: Int) {
                let gx = cx + marginCells, gy = cy + marginCells
                guard gx >= 0, gy >= 0, gx < gridW, gy < gridH else { return }
                let i = gy * gridW + gx
                if !grid[i] {
                    grid[i] = true
                    hitList.append(i)
                }
            }
            for (bx, by) in targets {
                guard let block = fog.block(bx, by) else { continue }
                let blockOriginX = bx * bw - originX
                let blockOriginY = by * bw - originY
                if bitsPerPixelLog2 >= 6 {
                    // 1 ブロック全体が 1 ピクセル以下：ブロック単位で印をつける。
                    mark(blockOriginX >> bitsPerCellLog2, blockOriginY >> bitsPerCellLog2)
                    continue
                }
                block.bitmap.withUnsafeBufferPointer { bits in
                    for j in 0..<bw {
                        for byteIndex in 0..<8 {
                            let byte = bits[j * 8 + byteIndex]
                            if byte == 0 { continue }
                            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                                mark((blockOriginX + byteIndex * 8 + bit) >> bitsPerCellLog2,
                                     (blockOriginY + j) >> bitsPerCellLog2)
                            }
                        }
                    }
                }
            }
        }

        // 2. 印のついたセルを抜く。
        if diameter > cellPx {
            clearDisks(&pixels, width: width, height: height, hitList: hitList, gridW: gridW,
                       marginCells: marginCells, cellPx: cellPx, diameter: diameter)
        } else {
            pixels.withUnsafeMutableBufferPointer { buf in
                for i in hitList {
                    let left = (i % gridW - marginCells) << cellLog2
                    let top = (i / gridW - marginCells) << cellLog2
                    let x0 = max(left, 0), x1 = min(left + cellPx, width)
                    guard x0 < x1 else { continue }
                    for y in max(top, 0)..<min(top + cellPx, height) {
                        let base = y * width
                        for x in x0..<x1 { buf[base + x] = 0 }
                    }
                }
            }
        }
        return pixels
    }

    /// 各セルの中心に直径 `diameter` の円を置き、その和の部分を透明にする。
    ///
    /// 円を 1 つずつ押すと円が大きいとき（縮小して太く見せるとき）に遅いので、
    /// まず列ごとに一番近いセル中心までの縦の距離を求め、行ごとに「その列の円がこの行で覆う区間」を
    /// 差分配列で重ねる。手間は円の大きさによらず画像の面積に比例する。
    static func clearDisks(_ pixels: inout [UInt32], width: Int, height: Int, hitList: [Int], gridW: Int,
                           marginCells: Int, cellPx: Int, diameter: Int) {
        let radius = Double(diameter) / 2
        let reach = Int(radius.rounded(.up))
        // 範囲外のセル中心も含めた、余白つきのピクセル格子。
        let margin = marginCells * cellPx
        let extW = width + margin * 2, extH = height + margin * 2
        // 縦の距離が dy のとき円が横に覆う半幅（中心から ±half まで）。届かなければ -1。
        let half: [Int] = (0...reach).map { dy in
            let h2 = radius * radius - Double(dy * dy)
            guard h2 > 0 else { return -1 }
            return Int(h2.squareRoot().rounded(.up)) - 1   // dx² < h2 を満たす最大の dx
        }
        let far = UInt16(reach + 1)
        // 列ごとの、一番近いセル中心までの縦の距離（reach を超えたら far）。
        var dist = [UInt16](repeating: far, count: extW * extH)
        dist.withUnsafeMutableBufferPointer { d in
            for i in hitList {
                let sx = (i % gridW) * cellPx + cellPx / 2
                let sy = (i / gridW) * cellPx + cellPx / 2
                guard sx < extW, sy < extH else { continue }
                d[sy * extW + sx] = 0
            }
            for y in 1..<extH {
                let row = y * extW, prev = row - extW
                for x in 0..<extW where d[prev + x] < far && d[prev + x] + 1 < d[row + x] {
                    d[row + x] = d[prev + x] + 1
                }
            }
            for y in stride(from: extH - 2, through: 0, by: -1) {
                let row = y * extW, next = row + extW
                for x in 0..<extW where d[next + x] < far && d[next + x] + 1 < d[row + x] {
                    d[row + x] = d[next + x] + 1
                }
            }
        }
        var cover = [Int32](repeating: 0, count: extW + 1)
        dist.withUnsafeBufferPointer { d in
            pixels.withUnsafeMutableBufferPointer { buf in
                cover.withUnsafeMutableBufferPointer { cov in
                    for y in 0..<height {
                        let row = (y + margin) * extW
                        var any = false
                        for x in 0..<extW {
                            let dy = Int(d[row + x])
                            guard dy <= reach else { continue }
                            let h = half[dy]
                            guard h >= 0 else { continue }
                            let x0 = max(x - h - margin, 0), x1 = min(x + h + 1 - margin, width)
                            guard x0 < x1 else { continue }
                            cov[x0] += 1
                            cov[x1] -= 1
                            any = true
                        }
                        guard any else { continue }
                        var count: Int32 = 0
                        let base = y * width
                        for x in 0..<width {
                            count += cov[x]
                            cov[x] = 0
                            if count > 0 { buf[base + x] = 0 }
                        }
                        cov[width] = 0
                    }
                }
            }
        }
    }

    static func image(fog: FogData, blocks: [(x: Int, y: Int)], originX: Int, originY: Int,
                      bitsPerPixelLog2: Int, width: Int, height: Int,
                      minDiameter: Int, color: FogRGB, opacity: Double) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let pixels = rgba(fog: fog, blocks: blocks, originX: originX, originY: originY,
                          bitsPerPixelLog2: bitsPerPixelLog2, width: width, height: height,
                          minDiameter: minDiameter, color: color, opacity: opacity)
        guard let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
