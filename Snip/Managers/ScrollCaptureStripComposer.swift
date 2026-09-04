import CoreGraphics

/// Composes only newly revealed scroll content while keeping fixed top/bottom chrome
/// at the outside edge of the final image.
struct ScrollCaptureStripComposer: Sendable {
    enum Edge: Sendable {
        case bottom
        case top
    }

    struct FixedInsets: Equatable, Sendable {
        let top: Int
        let bottom: Int

        nonisolated init(top: Int, bottom: Int) {
            self.top = top
            self.bottom = bottom
        }
    }

    nonisolated init() {}

    nonisolated func fixedInsets(previous: CGImage, current: CGImage) -> FixedInsets {
        guard previous.width == current.width,
              previous.height == current.height,
              let lhs = grayscale(previous),
              let rhs = grayscale(current) else {
            return FixedInsets(top: 0, bottom: 0)
        }

        let maximumInset = max(0, min(lhs.height / 5, 240))
        // CGContext's image buffer uses bottom-origin rows. Convert the scanned buffer
        // edges back to visual top/bottom semantics before composing.
        return FixedInsets(
            top: fixedBandLength(lhs: lhs, rhs: rhs, fromTop: false, limit: maximumInset),
            bottom: fixedBandLength(lhs: lhs, rhs: rhs, fromTop: true, limit: maximumInset)
        )
    }

    nonisolated func compose(
        base: CGImage,
        previousViewport: CGImage,
        currentViewport: CGImage,
        appendedPixels: Int,
        edge: Edge
    ) -> CGImage? {
        guard appendedPixels > 0,
              previousViewport.width == currentViewport.width,
              previousViewport.height == currentViewport.height else { return nil }

        let width = max(base.width, currentViewport.width)
        let height = base.height + appendedPixels
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        let insets = fixedInsets(previous: previousViewport, current: currentViewport)
        switch edge {
        case .bottom:
            let footer = min(insets.bottom, currentViewport.height - appendedPixels)

            // Move the existing image upward, excluding its old fixed footer.
            context.saveGState()
            context.clip(to: CGRect(
                x: 0,
                y: CGFloat(footer + appendedPixels),
                width: CGFloat(width),
                height: CGFloat(max(0, base.height - footer))
            ))
            context.draw(base, in: CGRect(
                x: 0,
                y: CGFloat(appendedPixels),
                width: CGFloat(base.width),
                height: CGFloat(base.height)
            ))
            context.restoreGState()

            // Current frame contributes one footer plus the document strip directly
            // above it. The footer remains only at the final outside edge.
            context.saveGState()
            context.clip(to: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(footer + appendedPixels)
            ))
            context.draw(currentViewport, in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(currentViewport.width),
                height: CGFloat(currentViewport.height)
            ))
            context.restoreGState()

        case .top:
            let header = min(insets.top, currentViewport.height - appendedPixels)

            // Keep the existing image except for its old fixed header.
            context.saveGState()
            context.clip(to: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(max(0, base.height - header))
            ))
            context.draw(base, in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(base.width),
                height: CGFloat(base.height)
            ))
            context.restoreGState()

            // Shift the current viewport upward in Quartz coordinates so its header
            // stays at the final top edge and its newly revealed strip follows it.
            context.saveGState()
            context.clip(to: CGRect(
                x: 0,
                y: CGFloat(base.height - header),
                width: CGFloat(width),
                height: CGFloat(header + appendedPixels)
            ))
            context.draw(currentViewport, in: CGRect(
                x: 0,
                y: CGFloat(appendedPixels),
                width: CGFloat(currentViewport.width),
                height: CGFloat(currentViewport.height)
            ))
            context.restoreGState()
        }

        return context.makeImage()
    }

    private struct GrayImage {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        nonisolated init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }
    }

    private nonisolated func grayscale(_ image: CGImage) -> GrayImage? {
        let width = min(image.width, 400)
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let created = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return created ? GrayImage(width: width, height: height, bytes: bytes) : nil
    }

    private nonisolated func fixedBandLength(
        lhs: GrayImage,
        rhs: GrayImage,
        fromTop: Bool,
        limit: Int
    ) -> Int {
        guard limit > 0 else { return 0 }
        var lastFixedRow = -1
        var consecutiveChangedRows = 0

        for distance in 0..<limit {
            let row = fromTop ? lhs.height - 1 - distance : distance
            var difference = 0
            var samples = 0
            for x in stride(from: 0, to: lhs.width, by: 4) {
                difference += abs(
                    Int(lhs.bytes[row * lhs.width + x])
                        - Int(rhs.bytes[row * rhs.width + x])
                )
                samples += 1
            }
            let meanDifference = samples > 0 ? Double(difference) / Double(samples) : .infinity
            if meanDifference <= 4.0 {
                lastFixedRow = distance
                consecutiveChangedRows = 0
            } else {
                consecutiveChangedRows += 1
                if consecutiveChangedRows >= 3 { break }
            }
        }

        return lastFixedRow >= 1 ? lastFixedRow + 1 : 0
    }

    private nonisolated func makeContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
