import AppKit
import CoreText
import VisionKit
import XCTest

enum ImageFixture {
    static func bitmap(width: Int = 1000, height: Int = 240, text: String = "CLIPBOARD 12345", fontName: String = "HelveticaNeue") throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, 72, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 30, y: 80); CTLineDraw(line, context)
        return try XCTUnwrap(context.makeImage())
    }
}

final class ImageGeometryTests: XCTestCase {
    @MainActor
    func testPortraitFitsAndOverlayTracksPixels() throws {
        let view = ImageZoomScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.imageContent.imageView.image = NSImage(cgImage: try ImageFixture.bitmap(width: 200, height: 400), size: .zero)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.imageContent.frame.width, 180, accuracy: 0.5)
        XCTAssertEqual(view.imageContent.frame.height, 360, accuracy: 0.5)
        XCTAssertEqual(view.imageContent.imageView.frame, view.imageContent.bounds)
        XCTAssertEqual(view.imageContent.overlay.frame, view.imageContent.bounds)
    }
    @MainActor
    func testLandscapeFitsAndResizesWithoutStretching() throws {
        let view = ImageZoomScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.imageContent.imageView.image = NSImage(cgImage: try ImageFixture.bitmap(width: 800, height: 200), size: .zero)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.imageContent.frame.size, NSSize(width: 640, height: 160))
        view.setFrameSize(NSSize(width: 400, height: 300)); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.imageContent.frame.size, NSSize(width: 400, height: 100))
    }
    @MainActor
    func testMagnificationBoundsAndTwoAxisScrolling() throws {
        let view = ImageZoomScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.imageContent.imageView.image = NSImage(cgImage: try ImageFixture.bitmap(width: 400, height: 400), size: .zero)
        view.layoutSubtreeIfNeeded()
        view.setMagnification(100, centeredAt: NSPoint(x: 300, y: 150))
        XCTAssertEqual(view.magnification, 6)
        XCTAssertGreaterThan(view.imageContent.frame.width, view.contentView.bounds.width)
        XCTAssertGreaterThan(view.imageContent.frame.height, view.contentView.bounds.height)
        view.setMagnification(0.01, centeredAt: .zero)
        XCTAssertEqual(view.magnification, 0.25)
    }
    @MainActor
    func testEmptyViewportDoesNotCreateInvalidGeometry() {
        let view = ImageZoomScrollView(frame: .zero)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.imageContent.frame.width.isFinite)
        XCTAssertTrue(view.imageContent.frame.height.isFinite)
    }
}

final class ImageRecognitionTests: XCTestCase {
    func testActualOCRBackendRecognizesGeneratedImage() throws {
        let image = NSImage(cgImage: try ImageFixture.bitmap(), size: .zero)
        recognize(image, expected: ["CLIPBOARD", "12345"])
    }
    func testActualOCRBackendRecognizesChineseImage() throws {
        let image = NSImage(cgImage: try ImageFixture.bitmap(text: "剪贴板 测试 12345", fontName: "PingFangSC-Regular"), size: .zero)
        recognize(image, expected: ["剪贴板", "测试", "12345"])
    }
    private func recognize(_ image: NSImage, expected: [String]) {
        XCTAssertTrue(ImageAnalyzer.isSupported, "此机器的系统实况文本不可用，不能将 OCR 验证计为通过")
        let done = expectation(description: "实际 VisionKit 识别完成")
        let task = Task { @MainActor in
            do {
                let result = try await ImageTextRecognition.analyze(image)
                guard !Task.isCancelled else { return }
                for token in expected { XCTAssertTrue(result.transcript.localizedCaseInsensitiveContains(token), result.transcript) }
            } catch { XCTFail("系统 OCR 后端失败：\(error)") }
            done.fulfill()
        }
        defer { task.cancel() }
        wait(for: [done], timeout: 30)
    }
}
