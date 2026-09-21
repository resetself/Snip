import AppKit
import XCTest
@testable import SnipScrollCaptureCore

final class AnnotationExportTests: XCTestCase {
    @MainActor
    private func render(_ layer: AnnotationLayer, scale: Int = 1, offset: CGFloat = 0) throws -> Data {
        let image = try XCTUnwrap(layer.captureAsImage(
            logicalSize: NSSize(width: 240, height: 120),
            pixelWidth: 240 * scale, pixelHeight: 120 * scale, offsetY: offset
        ))
        return try XCTUnwrap(image.pngData())
    }

    @MainActor
    func testPendingTextCommitsOnceAndSupportsUndoRedo() throws {
        let layer = AnnotationLayer(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let blank = try render(layer)
        let field = DraggableTextField(frame: NSRect(x: 20, y: 30, width: 180, height: 40))
        field.stringValue = "中文 Hello"
        field.font = .boldSystemFont(ofSize: 28)
        field.textColor = .red
        layer.addSubview(field)
        XCTAssertTrue(layer.commitPendingTextEdits())
        XCTAssertTrue(layer.subviews.isEmpty)
        let output = try render(layer)
        XCTAssertNotEqual(output, blank)
        XCTAssertTrue(layer.commitPendingTextEdits())
        XCTAssertEqual(try render(layer), output)
        layer.undo()
        XCTAssertFalse(layer.canUndo())
        XCTAssertEqual(try render(layer), blank)
        layer.redo()
        XCTAssertEqual(try render(layer), output)
        XCTAssertNotEqual(try render(layer, offset: 20), output)
        XCTAssertNotEqual(try render(layer, scale: 2), output)
    }

    @MainActor
    func testToolChangesKeepFrozenBaseAndShadowPixels() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * scale),
            height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        context.setShadow(offset: CGSize(width: 4, height: -4), blur: 10,
                          color: NSColor.black.withAlphaComponent(0.5).cgColor)
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 40, y: 40, width: 60, height: 60))
        let base = ManagedRasterImage(cgImage: try XCTUnwrap(context.makeImage()), logicalSize: size, label: "test-shadow")
        let view = CaptureView(frame: CGRect(origin: .zero, size: size), screen: screen,
                               initialScreenImage: base) { _, _ in }
        defer { view.cleanup() }
        view.applyAdjustedSelectionRect(CGRect(x: 0, y: 0, width: 240, height: 120))
        view.enterEditMode()
        let frozen = try XCTUnwrap(view.currentSelectionPreviewImage())
        let expected = try XCTUnwrap(view.renderFinalImage(from: frozen)?.pngData())
        let layer = try XCTUnwrap(view.subviews.compactMap { $0 as? AnnotationLayer }.first)
        for tool: AnnotationTool in [.text, .line, .rectangle, .pen, .mosaic, .select] {
            layer.currentTool = tool
            view.refreshAnnotationLayerMosaicSourceIfNeeded()
            XCTAssertTrue(view.currentSelectionPreviewImage() === frozen)
            XCTAssertEqual(view.renderFinalImage(from: frozen)?.pngData(), expected)
        }
        // A text annotation outside the output still forces the merge path; every
        // output pixel (including shadows) must remain unchanged.
        let outside = DraggableTextField(frame: CGRect(x: 500, y: 500, width: 100, height: 30))
        outside.stringValue = "outside"
        layer.addSubview(outside)
        XCTAssertTrue(layer.commitPendingTextEdits())
        XCTAssertEqual(view.renderFinalImage(from: frozen)?.pngData(), expected)
        view.reclaimTransientResources()
        XCTAssertTrue(view.currentSelectionPreviewImage() === frozen)
        view.applyAdjustedSelectionRect(CGRect(x: 1, y: 0, width: 240, height: 120))
        XCTAssertNil(view.currentSelectionPreviewImage())
    }

    @MainActor
    func testCommittedTextCanBeDraggedWithViewportOffset() throws {
        let layer = AnnotationLayer(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        let window = NSWindow(contentRect: layer.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = layer
        defer { window.contentView = nil; window.close() }
        let field = DraggableTextField(frame: CGRect(x: 20, y: 20, width: 140, height: 30))
        field.isBordered = false
        field.stringValue = "Move me"
        field.font = .systemFont(ofSize: 20)
        layer.addSubview(field)
        XCTAssertTrue(layer.commitPendingTextEdits())
        layer.setViewportOffset(15)
        let hitY = try XCTUnwrap((0..<110).first { layer.hitTestEditableContent(at: CGPoint(x: 30, y: $0)) })
        let start = CGPoint(x: 30, y: hitY + 2)
        let end = CGPoint(x: 200, y: hitY + 12)
        let before = try render(layer)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        layer.mouseDown(with: try event(.leftMouseDown, start))
        layer.mouseDragged(with: try event(.leftMouseDragged, end))
        layer.mouseUp(with: try event(.leftMouseUp, end))
        XCTAssertFalse(layer.hitTestEditableContent(at: start))
        XCTAssertTrue(layer.hitTestEditableContent(at: end))
        XCTAssertNotEqual(try render(layer), before)
    }

    @MainActor
    func testArrowNodeEditingAfterViewportScroll() throws {
        let layer = AnnotationLayer(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        let window = NSWindow(contentRect: layer.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = layer
        defer { window.contentView = nil; window.close() }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: layer.mouseDown(with: event)
            case .leftMouseDragged: layer.mouseDragged(with: event)
            default: layer.mouseUp(with: event)
            }
        }
        layer.currentTool = .line
        layer.currentStyle.lineStyle = .arrow
        try send(.leftMouseDown, CGPoint(x: 30, y: 30))
        try send(.leftMouseDragged, CGPoint(x: 140, y: 30))
        try send(.leftMouseUp, CGPoint(x: 140, y: 30))
        layer.currentTool = .select
        layer.setViewportOffset(20)
        XCTAssertTrue(layer.hitTestEditableContent(at: CGPoint(x: 140, y: 50)))
        let before = try render(layer, offset: 20)
        try send(.leftMouseDown, CGPoint(x: 140, y: 50))
        try send(.leftMouseDragged, CGPoint(x: 180, y: 80))
        try send(.leftMouseUp, CGPoint(x: 180, y: 80))
        XCTAssertTrue(layer.hitTestEditableContent(at: CGPoint(x: 180, y: 80)))
        XCTAssertNotEqual(try render(layer, offset: 20), before)
    }

    @MainActor
    func testEndingTextEditingDeactivatesTextToolOnly() {
        for text in ["Hello", ""] {
            let layer = AnnotationLayer(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
            layer.currentTool = .text
            let field = DraggableTextField(frame: CGRect(x: 20, y: 20, width: 100, height: 30))
            field.stringValue = text
            layer.addSubview(field)
            var selections: [AnnotationTool] = []
            layer.onToolSelectionChanged = { selections.append($0) }
            let notification = Notification(name: NSControl.textDidEndEditingNotification, object: field)
            layer.controlTextDidEndEditing(notification)
            layer.controlTextDidEndEditing(notification)
            XCTAssertEqual(layer.currentTool, .select)
            XCTAssertEqual(selections, [.select])
            XCTAssertTrue(layer.subviews.isEmpty)
            XCTAssertEqual(layer.canUndo(), !text.isEmpty)
        }

        let layer = AnnotationLayer(frame: .zero)
        layer.currentTool = .text
        let field = DraggableTextField(frame: .zero)
        field.stringValue = "Keep the new tool"
        layer.addSubview(field)
        var selectionChanged = false
        layer.onToolSelectionChanged = { _ in selectionChanged = true }
        layer.currentTool = .pen
        XCTAssertEqual(layer.currentTool, .pen)
        XCTAssertFalse(selectionChanged)
        XCTAssertTrue(layer.canUndo())
    }

    @MainActor
    func testTextDoesNotMoveWhenCommitted() throws {
        for scale in [1, 2] {
            let layer = AnnotationLayer(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
            let field = DraggableTextField(frame: CGRect(x: 20, y: 30, width: 180, height: 36))
            field.isBordered = false
            field.drawsBackground = false
            field.stringValue = "位置 Hello"
            field.font = .systemFont(ofSize: 24)
            field.textColor = .red
            layer.addSubview(field)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 240 * scale, pixelsHigh: 120 * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            bitmap.size = layer.bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let context = graphics.cgContext
            context.clear(CGRect(x: 0, y: 0, width: 240 * scale, height: 120 * scale))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.translateBy(x: field.frame.minX, y: field.frame.maxY)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            field.cell?.drawInterior(withFrame: field.bounds, in: field)
            NSGraphicsContext.restoreGraphicsState()
            let expected = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertTrue(layer.commitPendingTextEdits())
            func inkBounds(_ data: Data) throws -> CGRect {
                let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
                var bounds = CGRect.null
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                            bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                        }
                    }
                }
                return bounds
            }
            let before = try inkBounds(expected)
            let after = try inkBounds(render(layer, scale: scale))
            XCTAssertFalse(before.isNull)
            XCTAssertEqual(after.minY, before.minY, accuracy: 1)
            XCTAssertEqual(after.maxY, before.maxY, accuracy: 1)
            XCTAssertEqual(after.minX, before.minX, accuracy: 1)
            XCTAssertEqual(after.maxX, before.maxX, accuracy: 1)
        }
    }

    @MainActor
    func testEmptyFieldsDoNotBecomeAnnotations() {
        let layer = AnnotationLayer(frame: .zero)
        for value in ["", "  \n "] {
            let field = DraggableTextField(frame: .zero)
            field.stringValue = value
            layer.addSubview(field)
        }
        XCTAssertTrue(layer.commitPendingTextEdits())
        XCTAssertFalse(layer.hasRenderableContent())
        XCTAssertFalse(layer.canUndo())
    }

    @MainActor
    func testCommittedTextRetainsFontAndColorInsteadOfCurrentStyle() throws {
        func image(fontSize: CGFloat, color: NSColor, changeStyle: Bool) throws -> Data {
            let layer = AnnotationLayer(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
            let field = DraggableTextField(frame: NSRect(x: 15, y: 25, width: 180, height: 45))
            field.stringValue = "Styled text"
            field.font = .boldSystemFont(ofSize: fontSize)
            field.textColor = color
            layer.addSubview(field)
            if changeStyle {
                layer.currentStyle.color = .blue
                layer.currentStyle.fontSize = 8
            }
            XCTAssertTrue(layer.commitPendingTextEdits())
            return try render(layer)
        }
        let original = try image(fontSize: 28, color: .red, changeStyle: false)
        XCTAssertEqual(original, try image(fontSize: 28, color: .red, changeStyle: true))
        XCTAssertNotEqual(original, try image(fontSize: 16, color: .red, changeStyle: false))
        XCTAssertNotEqual(original, try image(fontSize: 28, color: .blue, changeStyle: false))
    }
}
