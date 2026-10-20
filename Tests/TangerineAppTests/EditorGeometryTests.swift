import CoreGraphics
@testable import TangerineApp
import XCTest

/// Pure crop/resize/history math behind the editor.
final class EditorGeometryTests: XCTestCase {
    private func assertInsideUnit(_ r: CGRect, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let e = 1e-9
        XCTAssertTrue(r.minX >= -e && r.minY >= -e && r.maxX <= 1 + e && r.maxY <= 1 + e, "\(r) \(message)", file: file, line: line)
    }

    private func pixelRatio(of crop: CGRect?, base: CGSize) -> CGFloat {
        let size = EditorCropMath.pixelSize(of: crop, baseSize: base)
        return size.width / size.height
    }

    func testAspectPresetsOnLandscapeAndPortrait() {
        for base in [CGSize(width: 4000, height: 3000), CGSize(width: 3000, height: 4000), CGSize(width: 1080, height: 1920)] {
            for aspect in EditorAspect.allCases where aspect != .free {
                for swapped in aspect.canSwap ? [false, true] : [false] {
                    let ratio = aspect.pixelRatio(baseSize: base, swapped: swapped)!
                    let crop = EditorCropMath.fit(ratio: EditorCropMath.normalizedRatio(pixelRatio: ratio, baseSize: base), in: EditorCropMath.unit)
                    assertInsideUnit(crop, "\(aspect) on \(base)")
                    XCTAssertEqual(pixelRatio(of: crop, base: base), ratio, accuracy: 0.01, "\(aspect) swapped \(swapped) on \(base)")
                    XCTAssertTrue(abs(crop.width - 1) < 1e-9 || abs(crop.height - 1) < 1e-9, "\(aspect) uses the largest crop")
                    XCTAssertEqual(crop.midX, 0.5, accuracy: 1e-9)
                    XCTAssertEqual(crop.midY, 0.5, accuracy: 1e-9)
                }
            }
        }
        XCTAssertTrue(EditorCropMath.isFull(EditorCropMath.fit(ratio: EditorCropMath.normalizedRatio(
            pixelRatio: EditorAspect.original.pixelRatio(baseSize: CGSize(width: 3000, height: 4000), swapped: false)!,
            baseSize: CGSize(width: 3000, height: 4000)), in: EditorCropMath.unit)), "Original keeps the whole image")
        XCTAssertNil(EditorAspect.free.pixelRatio(baseSize: CGSize(width: 10, height: 10), swapped: false))
    }

    func testCropDragsStayInsideTheImage() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let wild = [CGPoint(x: -3, y: -2), CGPoint(x: 5, y: 4), CGPoint(x: 0.21, y: 0.69), CGPoint(x: 0.7, y: 0.2)]
        for handle in EditorCropHandle.allCases where handle != .move {
            for point in wild {
                let free = EditorCropMath.resized(start, handle: handle, to: point, ratio: nil)
                assertInsideUnit(free, "\(handle) → \(point)")
                XCTAssertGreaterThanOrEqual(free.width, 0.02 - 1e-9, "\(handle) keeps a minimum size")
                XCTAssertGreaterThanOrEqual(free.height, 0.02 - 1e-9)
                for ratio: CGFloat in [1, 16.0 / 9.0, 0.3] {
                    let locked = EditorCropMath.resized(start, handle: handle, to: point, ratio: ratio)
                    assertInsideUnit(locked, "\(handle) → \(point) at \(ratio)")
                    XCTAssertEqual(locked.width / locked.height, ratio, accuracy: 0.001, "\(handle) keeps \(ratio)")
                }
            }
        }
        // Dragging the left edge past the right one stops at the minimum width instead of flipping.
        let squeezed = EditorCropMath.resized(start, handle: .left, to: CGPoint(x: 0.95, y: 0.5), ratio: nil)
        XCTAssertEqual(squeezed.maxX, start.maxX, accuracy: 1e-9)
        XCTAssertEqual(squeezed.width, 0.02, accuracy: 1e-9)

        let moved = EditorCropMath.moved(start, by: CGSize(width: 2, height: -2))
        XCTAssertEqual(moved, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    func testCropFollowsRotateAndFlip() {
        let crop = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        var r = crop
        for _ in 0..<4 { r = EditorCropMath.rotated(r, clockwise: true) }
        XCTAssertEqual(r.minX, crop.minX, accuracy: 1e-9)
        XCTAssertEqual(r.minY, crop.minY, accuracy: 1e-9)
        let back = EditorCropMath.rotated(EditorCropMath.rotated(crop, clockwise: true), clockwise: false)
        XCTAssertEqual(back.origin.x, crop.origin.x, accuracy: 1e-9)
        XCTAssertEqual(back.size.width, crop.size.width, accuracy: 1e-9)
        // A crop hugging the top-left ends up hugging the top-right after a clockwise turn.
        let corner = EditorCropMath.rotated(CGRect(x: 0, y: 0, width: 0.25, height: 0.5), clockwise: true)
        XCTAssertEqual(corner.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(corner.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(corner.size, CGSize(width: 0.5, height: 0.25))
        for horizontal in [true, false] {
            XCTAssertEqual(EditorCropMath.flipped(EditorCropMath.flipped(crop, horizontally: horizontal), horizontally: horizontal).origin.x,
                           crop.origin.x, accuracy: 1e-9)
        }
        XCTAssertEqual(EditorCropMath.flipped(crop, horizontally: true).minX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(EditorCropMath.flipped(crop, horizontally: false).minY, 0.4, accuracy: 1e-9)
    }

    func testResizePresets() {
        let odd = CGSize(width: 1001, height: 667)
        XCTAssertEqual(EditorResize.percent(50).outputSize(for: odd), CGSize(width: 501, height: 334))
        XCTAssertEqual(EditorResize.percent(25).outputSize(for: CGSize(width: 3, height: 1)), CGSize(width: 1, height: 1), "never zero")
        XCTAssertNil(EditorResize.longEdge(2048).outputSize(for: odd), "long-edge presets never upscale")
        XCTAssertFalse(EditorResize.longEdge(2048).applies(to: odd))
        XCTAssertEqual(EditorResize.longEdge(1080).outputSize(for: CGSize(width: 3024, height: 4032)), CGSize(width: 810, height: 1080))
        XCTAssertEqual(EditorResize.longEdge(1080).outputSize(for: CGSize(width: 20000, height: 3)), CGSize(width: 1080, height: 1))
        XCTAssertNil(EditorResize.original.outputSize(for: odd))
        XCTAssertNil(EditorResize.percent(50).outputSize(for: .zero))
        XCTAssertEqual(EditorResize.custom(width: 0, height: -5, locked: false).outputSize(for: odd), CGSize(width: 1, height: 1))
        XCTAssertEqual(EditorResize.custom(width: 2002, height: 9, locked: true).outputSize(for: odd), CGSize(width: 2002, height: 1334),
                       "locked follows the crop's aspect, and may upscale")
        XCTAssertEqual(EditorResize.custom(width: 300, height: 100, locked: false).rotated, .custom(width: 100, height: 300, locked: false))
    }

    func testLockedCustomSizeKeepsTypedValues() {
        // What the size fields do: typing a height derives the width; the result must show the typed height.
        for cropped in [CGSize(width: 1080, height: 1920), CGSize(width: 3024, height: 4032), CGSize(width: 333, height: 1000),
                        CGSize(width: 1920, height: 1080), CGSize(width: 7, height: 3000)] {
            for typed in stride(from: 20, through: 2400, by: 7) {
                // Below one pixel of width the aspect can't be kept at all; the lock wins then.
                guard CGFloat(typed) * cropped.width / cropped.height >= 1 else { continue }
                let width = max(1, Int((CGFloat(typed) * cropped.width / cropped.height).rounded()))
                let size = EditorResize.custom(width: width, height: typed, locked: true).outputSize(for: cropped)!
                XCTAssertEqual(size.width, CGFloat(width))
                XCTAssertEqual(size.height, CGFloat(typed), "typed height \(typed) on \(cropped)")
                XCTAssertEqual(size.width / size.height, cropped.width / cropped.height,
                               accuracy: cropped.width / cropped.height / CGFloat(min(typed, width)) + 0.001, "aspect kept")
            }
        }
        // A size from another crop doesn't stick: the height follows the new aspect.
        XCTAssertEqual(EditorResize.custom(width: 1000, height: 750, locked: true).outputSize(for: CGSize(width: 500, height: 500)),
                       CGSize(width: 1000, height: 1000))
    }

    func testHistory() {
        var history = EditorHistory<Int>(limit: 3)
        history.record(before: 1, after: 1)
        XCTAssertFalse(history.canUndo, "no-op changes aren't recorded")
        for value in 0..<5 { history.record(before: value, after: value + 1) }
        XCTAssertEqual(history.undoStack, [2, 3, 4], "oldest steps drop past the limit")
        XCTAssertEqual(history.undo(from: 5), 4)
        XCTAssertEqual(history.undo(from: 4), 3)
        XCTAssertEqual(history.redo(from: 3), 4)
        history.record(before: 4, after: 9)
        XCTAssertFalse(history.canRedo, "a new edit clears redo")
        XCTAssertEqual(history.undo(from: 9), 4)
        history.clear()
        XCTAssertNil(history.undo(from: 1))
    }

    func testCanvasMappingAndHandles() {
        let frame = EditorCanvasLayout.imageFrame(imageSize: CGSize(width: 4000, height: 1000), bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                                                  padding: 20, zoom: 1, pan: CGSize(width: 500, height: 500))
        XCTAssertEqual(frame.width, 760, accuracy: 0.001, "fits the padded width")
        XCTAssertEqual(frame.midX, 400, accuracy: 0.001, "a fitting image can't be panned")
        let mapping = EditorImageMapping(frame: frame)
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let view = mapping.viewRect(crop)
        XCTAssertEqual(mapping.normalized(CGPoint(x: view.minX, y: view.maxY)).x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(mapping.normalized(CGPoint(x: view.minX, y: view.maxY)).y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(mapping.handle(at: CGPoint(x: view.minX, y: view.maxY), crop: crop), .topLeft)
        XCTAssertEqual(mapping.handle(at: CGPoint(x: view.maxX + 3, y: view.midY), crop: crop), .right)
        XCTAssertEqual(mapping.handle(at: CGPoint(x: view.midX, y: view.midY), crop: crop), .move)
        XCTAssertNil(mapping.handle(at: CGPoint(x: view.maxX + 60, y: view.midY), crop: crop))
        XCTAssertEqual(EditorImageMapping(frame: .zero).normalized(CGPoint(x: 5, y: 5)), .zero, "empty frame never divides by zero")
    }
}
