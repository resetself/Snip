import AppKit
import ImageIO
import UniformTypeIdentifiers

final class ManagedRasterImage {
    private let identifier = UUID().uuidString
    private let label: String

    let cgImage: CGImage
    let logicalSize: NSSize

    var pixelWidth: Int { cgImage.width }
    var pixelHeight: Int { cgImage.height }
    var estimatedByteCount: Int {
        let bytesPerRow = cgImage.bytesPerRow
        if bytesPerRow > 0 {
            return bytesPerRow * cgImage.height
        }
        return max(1, cgImage.width * cgImage.height * 4)
    }

    init(cgImage: CGImage, logicalSize: NSSize, label: String) {
        self.cgImage = cgImage
        self.logicalSize = logicalSize
        self.label = label

        Logger.log(
            "🖼️ ManagedRasterImage + \(label) [\(identifier)] \(pixelWidth)x\(pixelHeight) / \(ByteCountFormatter.string(fromByteCount: Int64(estimatedByteCount), countStyle: .memory))"
        )
    }

    convenience init?(nsImage: NSImage, label: String) {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        self.init(cgImage: cgImage, logicalSize: nsImage.size, label: label)
    }

    func makeBitmapImageRep() -> NSBitmapImageRep {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        bitmapRep.size = logicalSize
        return bitmapRep
    }

    func makeNSImage() -> NSImage {
        let image = NSImage(size: logicalSize)
        image.addRepresentation(makeBitmapImageRep())
        image.cacheMode = .never
        return image
    }

    func makeNSImageForPasteboard() -> NSImage {
        // 为剪贴板创建独立的图片数据，避免持有原始 CGImage 引用
        let image = NSImage(size: logicalSize)
        image.cacheMode = .never

        // 使用 TIFF 数据作为中间格式，打破对原始 CGImage 的引用
        autoreleasepool {
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            bitmapRep.size = logicalSize

            if let tiffData = bitmapRep.tiffRepresentation,
               let newRep = NSBitmapImageRep(data: tiffData) {
                newRep.size = logicalSize
                image.addRepresentation(newRep)
            } else {
                // 降级方案：直接使用 bitmap rep
                image.addRepresentation(bitmapRep)
            }
        }

        return image
    }

    func write(to url: URL) throws {
        let fileExtension = url.pathExtension.lowercased()
        let destinationType: UTType = (fileExtension == "jpg" || fileExtension == "jpeg") ? .jpeg : .png

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            destinationType.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "Snip.ManagedRasterImage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建图片导出目标"]
            )
        }

        let properties: CFDictionary?
        if destinationType == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary
        } else {
            properties = nil
        }

        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "Snip.ManagedRasterImage",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "图片导出失败"]
            )
        }
    }

    func draw(
        in rect: CGRect,
        context: CGContext,
        interpolation: CGInterpolationQuality = .default,
        antialias: Bool = true
    ) {
        context.saveGState()
        context.interpolationQuality = interpolation
        context.setShouldAntialias(antialias)
        context.draw(cgImage, in: rect)
        context.restoreGState()
    }

    deinit {
        Logger.log(
            "🖼️ ManagedRasterImage - \(label) [\(identifier)] \(pixelWidth)x\(pixelHeight) / \(ByteCountFormatter.string(fromByteCount: Int64(estimatedByteCount), countStyle: .memory))"
        )
    }
}

final class RasterImageView: NSView {
    var image: ManagedRasterImage? {
        didSet {
            if oldValue !== image {
                // 清理旧图片的 layer 缓存
                layer?.contents = nil
            }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 禁用 layer backing 以避免额外的内存开销
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let image,
              let context = NSGraphicsContext.current?.cgContext else { return }

        context.clear(bounds)
        image.draw(in: bounds, context: context, interpolation: .high)
    }

    func releaseResources() {
        image = nil
        layer?.contents = nil
        needsDisplay = true
    }
}
