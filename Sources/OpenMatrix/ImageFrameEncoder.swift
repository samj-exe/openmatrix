import UIKit

enum ImageFrameEncoder {
    static let width = 32
    static let height = 32
    private static let saturationBoostKey = "saturationBoost"
    private static let contrastKey = "imageContrast"
    private static let sharpnessKey = "imageSharpness"
    private static let orientationKey = "imageOrientation"
    private static let mirroredKey = "imageMirrored"

    static var savedSaturationBoost: Double {
        savedNumber(forKey: saturationBoostKey, default: 1)
    }

    static var savedContrast: Double {
        savedNumber(forKey: contrastKey, default: 1)
    }

    static var savedSharpness: Double {
        savedNumber(forKey: sharpnessKey, default: 0)
    }

    static var savedOrientation: Int {
        let value = UserDefaults.standard.integer(forKey: orientationKey)
        return [0, 90, 180, 270].contains(value) ? value : 0
    }

    static var savedMirrored: Bool {
        UserDefaults.standard.bool(forKey: mirroredKey)
    }

    static func rgbFrame(
        from data: Data,
        saturationBoost: Double = savedSaturationBoost,
        contrast: Double = savedContrast,
        sharpness: Double = savedSharpness,
        orientation: Int = savedOrientation,
        mirrored: Bool = savedMirrored
    ) throws -> Data {
        guard let image = UIImage(data: data), image.cgImage != nil else {
            throw FrameError.invalidImage
        }
        guard saturationBoost.isFinite, contrast.isFinite, sharpness.isFinite else {
            throw FrameError.invalidAdjustment
        }
        guard [0, 90, 180, 270].contains(orientation) else {
            throw FrameError.invalidOrientation
        }

        let sourceWidth = image.size.width
        let sourceHeight = image.size.height
        let isQuarterTurn = orientation == 90 || orientation == 270
        let orientedWidth = isQuarterTurn ? sourceHeight : sourceWidth
        let orientedHeight = isQuarterTurn ? sourceWidth : sourceHeight
        let scale = max(CGFloat(width) / orientedWidth, CGFloat(height) / orientedHeight)
        let drawWidth = orientedWidth * scale
        let drawHeight = orientedHeight * scale
        let logicalDrawRect = CGRect(
            x: (CGFloat(width) - drawWidth) / 2,
            y: (CGFloat(height) - drawHeight) / 2,
            width: orientedWidth * scale,
            height: orientedHeight * scale
        )
        let drawRect = sourceDrawRect(from: logicalDrawRect, orientation: orientation)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let normalizedImage = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.saveGState()
            switch orientation {
            case 90:
                context.translateBy(x: CGFloat(width), y: 0)
                context.rotate(by: .pi / 2)
            case 180:
                context.translateBy(x: CGFloat(width), y: CGFloat(height))
                context.rotate(by: .pi)
            case 270:
                context.translateBy(x: 0, y: CGFloat(height))
                context.rotate(by: -.pi / 2)
            default:
                break
            }
            image.draw(in: drawRect)
            context.restoreGState()
        }
        guard let normalizedCGImage = normalizedImage.cgImage else {
            throw FrameError.cannotRender
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(normalizedCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw FrameError.cannotRender
        }

        var rgb = Data(capacity: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let sourceX = mirrored ? width - 1 - x : x
                let offset = (y * width + sourceX) * 4
                let (red, green, blue) = boostedColor(
                    red: pixels[offset],
                    green: pixels[offset + 1],
                    blue: pixels[offset + 2],
                    saturationBoost: saturationBoost,
                    contrast: contrast
                )
                rgb.append(red)
                rgb.append(green)
                rgb.append(blue)
            }
        }
        return sharpness == 0 ? rgb : sharpen(rgb, amount: sharpness)
    }

    private static func savedNumber(forKey key: String, default defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        let value = UserDefaults.standard.double(forKey: key)
        return value.isFinite ? value : defaultValue
    }

    private static func sourceDrawRect(from logicalRect: CGRect, orientation: Int) -> CGRect {
        switch orientation {
        case 90:
            return CGRect(
                x: logicalRect.minY,
                y: CGFloat(width) - logicalRect.maxX,
                width: logicalRect.height,
                height: logicalRect.width
            )
        case 180:
            return CGRect(
                x: CGFloat(width) - logicalRect.maxX,
                y: CGFloat(height) - logicalRect.maxY,
                width: logicalRect.width,
                height: logicalRect.height
            )
        case 270:
            return CGRect(
                x: CGFloat(height) - logicalRect.maxY,
                y: logicalRect.minX,
                width: logicalRect.height,
                height: logicalRect.width
            )
        default:
            return logicalRect
        }
    }

    private static func boostedColor(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        saturationBoost: Double,
        contrast: Double
    ) -> (UInt8, UInt8, UInt8) {
        if saturationBoost == 1, contrast == 1 {
            return (red, green, blue)
        }
        let r = Double(red) / 255
        let g = Double(green) / 255
        let b = Double(blue) / 255
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum
        guard delta > 0 else {
            return (
                adjustContrast(r, amount: contrast),
                adjustContrast(g, amount: contrast),
                adjustContrast(b, amount: contrast)
            )
        }

        var hue: Double
        if maximum == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }

        let saturation = min(1, max(0, (delta / maximum) * saturationBoost))
        let chroma = maximum * saturation
        let intermediate = chroma * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let match = maximum - chroma
        let sector = Int(hue * 6)
        let components: (Double, Double, Double)
        switch sector {
        case 0: components = (chroma, intermediate, 0)
        case 1: components = (intermediate, chroma, 0)
        case 2: components = (0, chroma, intermediate)
        case 3: components = (0, intermediate, chroma)
        case 4: components = (intermediate, 0, chroma)
        default: components = (chroma, 0, intermediate)
        }

        return (
            adjustContrast(components.0 + match, amount: contrast),
            adjustContrast(components.1 + match, amount: contrast),
            adjustContrast(components.2 + match, amount: contrast)
        )
    }

    private static func adjustContrast(_ component: Double, amount: Double) -> UInt8 {
        let adjusted = min(255, max(0, (component * 255 - 127.5) * amount + 127.5))
        return UInt8(adjusted.rounded())
    }

    private static func sharpen(_ rgb: Data, amount: Double) -> Data {
        let source = [UInt8](rgb)
        var result = source

        for y in 0..<height {
            for x in 0..<width {
                let center = (y * width + x) * 3
                for channel in 0..<3 {
                    var total = 0
                    var count = 0
                    for neighborY in max(0, y - 1)...min(height - 1, y + 1) {
                        for neighborX in max(0, x - 1)...min(width - 1, x + 1) {
                            guard neighborX != x || neighborY != y else { continue }
                            total += Int(source[(neighborY * width + neighborX) * 3 + channel])
                            count += 1
                        }
                    }
                    let original = Double(source[center + channel])
                    let average = Double(total) / Double(count)
                    let sharpened = min(255, max(0, original + amount * (original - average)))
                    result[center + channel] = UInt8(sharpened.rounded())
                }
            }
        }
        return Data(result)
    }

    private enum FrameError: LocalizedError {
        case invalidImage
        case cannotRender
        case invalidAdjustment
        case invalidOrientation

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "The selected file is not a readable image."
            case .cannotRender:
                return "OpenMatrix could not convert the image for the display."
            case .invalidAdjustment:
                return "Image adjustments must be finite numbers."
            case .invalidOrientation:
                return "Image orientation must be 0, 90, 180, or 270 degrees."
            }
        }
    }
}
