import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SitePreviewImageProcessor {
    public static func pngData(from sourceData: Data, pixelSize: CGSize) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            pixelSize.width > 0,
            pixelSize.height > 0
        else { return nil }

        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        let sourceRect = SitePreviewSizing.aspectFillSourceRect(
            imageSize: CGSize(width: image.width, height: image.height),
            destinationSize: pixelSize
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: sourceRect), !sourceRect.isEmpty else { return nil }
        context.draw(cropped, in: CGRect(origin: .zero, size: pixelSize))
        guard let output = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
