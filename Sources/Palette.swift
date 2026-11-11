import AppKit
import SwiftUI

/// Four colors pulled from the album cover, plus a bright accent readable on black.
struct Palette: Equatable {
    var colors: [Color]
    var accent: Color

    static let fallback = Palette(
        colors: [
            Color(hue: 0.40, saturation: 0.75, brightness: 0.70),
            Color(hue: 0.48, saturation: 0.70, brightness: 0.55),
            Color(hue: 0.33, saturation: 0.65, brightness: 0.80),
            Color(hue: 0.55, saturation: 0.60, brightness: 0.45),
        ],
        accent: Color(hue: 0.40, saturation: 0.65, brightness: 0.95))

    private struct HSV { var h: Double; var s: Double; var v: Double }

    static func from(_ image: NSImage) -> Palette {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .fallback }

        let side = 40
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .fallback }

        // Bucket vivid pixels by hue; each bucket keeps a weighted average color.
        let binCount = 12
        var sums = [(r: Double, g: Double, b: Double, w: Double)](
            repeating: (0, 0, 0, 0), count: binCount)
        var totalWeight = 0.0
        var brightnessSum = 0.0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let hsv = toHSV(r, g, b)
            brightnessSum += hsv.v
            guard hsv.v > 0.18, hsv.s > 0.2 else { continue }
            let weight = hsv.s * (0.4 + hsv.v)
            let bin = min(Int(hsv.h * Double(binCount)), binCount - 1)
            sums[bin].r += r * weight
            sums[bin].g += g * weight
            sums[bin].b += b * weight
            sums[bin].w += weight
            totalWeight += weight
        }

        let pixelCount = Double(side * side)
        var base: [HSV] = sums
            .filter { $0.w > max(totalWeight * 0.05, pixelCount * 0.004) }
            .sorted { $0.w > $1.w }
            .prefix(4)
            .map { toHSV($0.r / $0.w, $0.g / $0.w, $0.b / $0.w) }

        // Grayscale cover: neutral tones around its average brightness.
        if base.isEmpty {
            let v = min(max(brightnessSum / pixelCount, 0.35), 0.8)
            let grays = [v, v * 0.55, min(v * 1.25, 0.95), v * 0.75].map { Color(white: $0) }
            return Palette(colors: grays, accent: Color(white: 0.92))
        }

        // Tune for a dark panel: keep hue, lift brightness, keep saturation lively.
        base = base.map { HSV(h: $0.h, s: min(max($0.s, 0.5), 0.95), v: min(max($0.v, 0.55), 0.92)) }

        // Fewer than four hues: derive neighbours by nudging hue and brightness.
        let shifts: [(dh: Double, dv: Double)] = [(0.05, -0.22), (-0.06, 0.08), (0.10, -0.32)]
        var index = 0
        while base.count < 4 {
            let source = base[index % base.count]
            let shift = shifts[index % shifts.count]
            var h = source.h + shift.dh
            h -= h.rounded(.down)
            base.append(HSV(h: h, s: source.s, v: min(max(source.v + shift.dv, 0.3), 0.95)))
            index += 1
        }

        let lead = base[0]
        return Palette(
            colors: base.map { Color(hue: $0.h, saturation: $0.s, brightness: $0.v) },
            accent: Color(hue: lead.h, saturation: min(lead.s, 0.6), brightness: 1.0))
    }

    private static func toHSV(_ r: Double, _ g: Double, _ b: Double) -> HSV {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0.0001 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return HSV(h: h, s: maxC > 0 ? delta / maxC : 0, v: maxC)
    }
}
