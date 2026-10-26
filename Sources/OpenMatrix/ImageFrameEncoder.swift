import UIKit

enum ImageFrameEncoder {
    static let width = 32
    static let height = 32

    static func rgbFrame(from data: Data) throws -> Data {
        guard let image = UIImage(data: data), image.cgImage != nil else {
            throw FrameError.invalidImage
        }

        let sourceWidth = image.size.width
        let sourceHeight = image.size.height
        let scale = max(CGFloat(width) / sourceWidth, CGFloat(height) / sourceHeight)
        let drawWidth = sourceWidth * scale
        let drawHeight = sourceHeight * scale
        let drawRect = CGRect(
            x: (CGFloat(width) - drawWidth) / 2,
            y: (CGFloat(height) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let normalizedImage = renderer.image { rendererContext in
            rendererContext.cgContext.setFillColor(UIColor.black.cgColor)
            rendererContext.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
            image.draw(in: drawRect)
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
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            rgb.append(pixels[offset])
            rgb.append(pixels[offset + 1])
            rgb.append(pixels[offset + 2])
        }
        return rgb
    }

    private enum FrameError: LocalizedError {
        case invalidImage
        case cannotRender

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "The selected file is not a readable image."
            case .cannotRender:
                return "OpenMatrix could not convert the image for the display."
            }
        }
    }
}
