import CoreGraphics
import Foundation
import Testing
@testable import SnipScrollCaptureCore

private struct SyntheticCodeDocument {
    let width = 300
    let viewportHeight = 360
    let lineHeight = 12
    let fixedChrome: Bool
    let periodic: Bool

    func frame(at scroll: Int) -> CGImage {
        var pixels = [UInt8](repeating: 242, count: width * viewportHeight)
        for y in 0..<viewportHeight {
            for x in 0..<width {
                if fixedChrome && (y < 24 || y >= viewportHeight - 18) {
                    pixels[y * width + x] = UInt8(30 + (x * 7 + y * 3) % 60)
                    continue
                }
                if fixedChrome && x < 42 {
                    pixels[y * width + x] = UInt8(185 + ((y / lineHeight) % 2) * 8)
                    continue
                }
                if fixedChrome && x >= width - 24 {
                    pixels[y * width + x] = UInt8(90 + (y * 5 + x) % 80)
                    continue
                }

                let documentY = y + scroll
                let line = documentY / lineHeight
                let withinLine = documentY % lineHeight
                let effectiveLine = periodic ? line % 4 : line
                var value = 248
                if withinLine == 3 || withinLine == 4 {
                    let indent = 50 + (effectiveLine * 13) % 55
                    let length = 45 + (effectiveLine * 29) % 145
                    if x >= indent && x < min(width - 28, indent + length) {
                        value = 35 + (effectiveLine * 37 + x * 3) % 150
                    }
                }
                if !periodic && x > 65 && x < 70 && documentY % 97 < 5 {
                    value = 15
                }
                pixels[y * width + x] = UInt8(value)
            }
        }
        return makeGrayImage(width: width, height: viewportHeight, pixels: pixels)
    }
}

@Test("Downward composition keeps one footer and appends only new document pixels")
func downwardStripComposition() {
    let composer = ScrollCaptureStripComposer()
    let previous = makeChromeViewport(scroll: 0)
    let current = makeChromeViewport(scroll: 20)
    let result = composer.compose(
        base: previous,
        previousViewport: previous,
        currentViewport: current,
        appendedPixels: 20,
        edge: .bottom
    )
    #expect(composer.fixedInsets(previous: previous, current: current) == .init(top: 10, bottom: 12))
    #expect(result?.height == previous.height + 20)
    guard let result, let rows = grayscaleRows(result) else { return }
    #expect(Array(rows[0..<10]).allSatisfy { $0 == 20 })
    #expect(Array(rows[10..<108]) == (0..<98).map(chromeDocumentValue))
    #expect(Array(rows[108..<120]).allSatisfy { $0 == 230 })
}

@Test("Upward composition keeps one header and prepends only new document pixels")
func upwardStripComposition() {
    let composer = ScrollCaptureStripComposer()
    let previous = makeChromeViewport(scroll: 20)
    let current = makeChromeViewport(scroll: 0)
    let result = composer.compose(
        base: previous,
        previousViewport: previous,
        currentViewport: current,
        appendedPixels: 20,
        edge: .top
    )
    #expect(composer.fixedInsets(previous: previous, current: current) == .init(top: 10, bottom: 12))
    #expect(result?.height == previous.height + 20)
    guard let result, let rows = grayscaleRows(result) else { return }
    #expect(Array(rows[0..<10]).allSatisfy { $0 == 20 })
    #expect(Array(rows[10..<108]) == (0..<98).map(chromeDocumentValue))
    #expect(Array(rows[108..<120]).allSatisfy { $0 == 230 })
}

@Test("Ordinary mixed-content pages remain a regression baseline")
func ordinaryPage() {
    let estimator = ScrollCaptureTranslationEstimator()
    let previous = makeOrdinaryPageFrame(scroll: 140)
    let current = makeOrdinaryPageFrame(scroll: 263)
    let result = estimator.estimate(
        previous: previous,
        current: current,
        expectedDirection: 1
    )
    #expect(result.status == .accepted)
    #expect(abs(result.verticalOffsetInPixels - 123) <= 2)
}

@Test("A continuous code viewport sequence preserves cumulative travel")
func continuousCodeSequence() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    let positions = [100, 137, 233, 341, 522, 603]
    var cumulativeOffset = 0
    for pair in zip(positions, positions.dropFirst()) {
        let result = estimator.estimate(
            previous: document.frame(at: pair.0),
            current: document.frame(at: pair.1),
            expectedDirection: 1
        )
        #expect(result.status == .accepted)
        cumulativeOffset += result.verticalOffsetInPixels
    }
    #expect(abs(cumulativeOffset - (positions.last! - positions.first!)) <= positions.count)
}

@Test("Final sub-line residual offsets remain measurable")
func finalResidualOffsets() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    for offset in 1...5 {
        let result = estimator.estimate(
            previous: document.frame(at: 211),
            current: document.frame(at: 211 + offset),
            expectedDirection: 1
        )
        #expect(result.status == .accepted)
        #expect(result.verticalOffsetInPixels == offset)
    }
}

@Test("Code offsets are recovered at integer and non-line-aligned positions")
func codeOffsets() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: false, periodic: false)
    for offset in [12, 37, 96, 173, 250] {
        let result = estimator.estimate(
            previous: document.frame(at: 100),
            current: document.frame(at: 100 + offset),
            expectedDirection: 1
        )
        #expect(result.status == .accepted)
        #expect(abs(result.verticalOffsetInPixels - offset) <= 2)
    }
}

@Test("Fixed gutter, header, status bar, and minimap cannot dominate")
func fixedEditorChrome() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    for offset in [12, 48, 108, 181] {
        let result = estimator.estimate(
            previous: document.frame(at: 200),
            current: document.frame(at: 200 + offset),
            expectedDirection: 1
        )
        #expect(result.status == .accepted)
        #expect(abs(result.verticalOffsetInPixels - offset) <= 2)
    }
}

@Test("Reverse scrolling uses image direction instead of wheel distance")
func reverseScrolling() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    let result = estimator.estimate(
        previous: document.frame(at: 420),
        current: document.frame(at: 301),
        expectedDirection: -1
    )
    #expect(result.status == .accepted)
    #expect(abs(result.verticalOffsetInPixels + 119) <= 2)
}

@Test("Identical frames are duplicates")
func duplicateFrames() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    let frame = document.frame(at: 300)
    let result = estimator.estimate(previous: frame, current: frame)
    #expect(result.status == .duplicate)
}

@Test("Small cursor-like changes do not corrupt the document offset")
func cursorAndSelectionChanges() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    let previous = document.frame(at: 180)
    let scrolled = document.frame(at: 267)
    let current = overlayRectangle(
        on: scrolled,
        rect: CGRect(x: 88, y: 141, width: 2, height: 13),
        value: 255
    )
    let result = estimator.estimate(
        previous: previous,
        current: current,
        expectedDirection: 1
    )
    #expect(result.status == .accepted)
    #expect(abs(result.verticalOffsetInPixels - 87) <= 2)
}

@Test("Two-times pixel density preserves the original pixel offset")
func retinaScale() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    let previous = scaleNearest(document.frame(at: 100), factor: 2)
    let current = scaleNearest(document.frame(at: 173), factor: 2)
    let result = estimator.estimate(
        previous: previous,
        current: current,
        expectedDirection: 1
    )
    #expect(result.status == .accepted)
    #expect(abs(result.verticalOffsetInPixels - 146) <= 3)
}

@Test("Large Retina viewport keeps exact source-pixel coordinates")
func largeRetinaViewport() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    let previous = scaleNearest(document.frame(at: 100), factor: 4)
    let current = scaleNearest(document.frame(at: 257), factor: 4)
    let started = ContinuousClock.now
    let result = estimator.estimate(
        previous: previous,
        current: current,
        expectedDirection: 1
    )
    let elapsed = ContinuousClock.now - started
    #expect(result.status == .accepted)
    #expect(abs(result.verticalOffsetInPixels - 628) <= 5)
    #expect(elapsed < .seconds(1))
}

@Test("Wrong direction never manufactures a reverse match")
func wrongDirectionIsRejected() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: false)
    let result = estimator.estimate(
        previous: document.frame(at: 100),
        current: document.frame(at: 196),
        expectedDirection: -1
    )
    #expect(result.status == .invalid)
}

@Test("Blank low-texture pages are rejected")
func lowTextureIsRejected() {
    let estimator = ScrollCaptureTranslationEstimator()
    let blank = makeGrayImage(
        width: 300,
        height: 360,
        pixels: [UInt8](repeating: 240, count: 300 * 360)
    )
    let result = estimator.estimate(previous: blank, current: blank)
    #expect(result.status == .duplicate)
}

@Test("Different frame sizes are invalid")
func differentSizesAreInvalid() {
    let estimator = ScrollCaptureTranslationEstimator()
    let lhs = makeGrayImage(width: 300, height: 360, pixels: [UInt8](repeating: 10, count: 300 * 360))
    let rhs = makeGrayImage(width: 301, height: 360, pixels: [UInt8](repeating: 10, count: 301 * 360))
    #expect(estimator.estimate(previous: lhs, current: rhs).status == .invalid)
}

@Test("Fundamentally periodic code is not guessed")
func periodicCodeIsRejected() {
    let estimator = ScrollCaptureTranslationEstimator()
    let document = SyntheticCodeDocument(fixedChrome: true, periodic: true)
    let result = estimator.estimate(
        previous: document.frame(at: 100),
        current: document.frame(at: 148),
        expectedDirection: 1
    )
    #expect(result.status != .accepted)
}

private func chromeDocumentValue(_ position: Int) -> UInt8 {
    UInt8(60 + (position % 140))
}

private func makeChromeViewport(scroll: Int) -> CGImage {
    let width = 80
    let height = 100
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        let value: UInt8
        if y < 10 {
            value = 20
        } else if y >= height - 12 {
            value = 230
        } else {
            value = chromeDocumentValue(scroll + y - 10)
        }
        for x in 0..<width {
            pixels[y * width + x] = value
        }
    }
    return makeGrayImage(width: width, height: height, pixels: pixels)
}

private func grayscaleRows(_ image: CGImage) -> [UInt8]? {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    return (0..<height).map { pixels[$0 * width + width / 2] }
}

private func makeOrdinaryPageFrame(scroll: Int) -> CGImage {
    let width = 420
    let height = 500
    var pixels = [UInt8](repeating: 248, count: width * height)
    for y in 0..<height {
        let documentY = y + scroll
        for x in 0..<width {
            let section = documentY / 85
            let localY = documentY % 85
            var value: UInt8 = 248
            if localY < 22 && x > 24 && x < 250 {
                let shade = 35 + (section * 29 + x) % 80
                value = UInt8(shade)
            } else if localY >= 30 && localY < 67 && x > 30 && x < 390 {
                let cardColumn = (x - 30) / 90
                let shade = 150 + (section * 17 + cardColumn * 23 + localY) % 80
                value = UInt8(shade)
            }
            if x < 14 {
                value = 225 // fixed page margin, not enough to dominate
            }
            pixels[y * width + x] = value
        }
    }
    return makeGrayImage(width: width, height: height, pixels: pixels)
}

private func overlayRectangle(on image: CGImage, rect: CGRect, value: UInt8) -> CGImage {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let x0 = max(0, Int(rect.minX))
    let x1 = min(width, Int(rect.maxX))
    let y0 = max(0, Int(rect.minY))
    let y1 = min(height, Int(rect.maxY))
    for y in y0..<y1 {
        for x in x0..<x1 {
            pixels[y * width + x] = value
        }
    }
    return makeGrayImage(width: width, height: height, pixels: pixels)
}

private func scaleNearest(_ image: CGImage, factor: Int) -> CGImage {
    let width = image.width * factor
    let height = image.height * factor
    var pixels = [UInt8](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return makeGrayImage(width: width, height: height, pixels: pixels)
}

private func makeGrayImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
