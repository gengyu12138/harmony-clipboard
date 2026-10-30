import AppKit
import SwiftUI
import VisionKit

/// The overlay tracks the same image view at every zoom level, keeping selections on the pixels.
struct LiveTextImage: NSViewRepresentable {
    let image: NSImage
    let analysis: ImageAnalysis?
    @Binding var selectedText: String
    @Binding var zoom: Double
    func makeNSView(context: Context) -> ImageZoomScrollView {
        let view = ImageZoomScrollView()
        view.imageContent.overlay.delegate = context.coordinator
        context.coordinator.selection = $selectedText
        return view
    }
    func updateNSView(_ view: ImageZoomScrollView, context: Context) {
        context.coordinator.selection = $selectedText
        if view.imageContent.imageView.image !== image {
            view.imageContent.imageView.image = image
            view.needsLayout = true
        }
        if view.imageContent.overlay.analysis !== analysis { view.imageContent.overlay.analysis = analysis }
        let binding = $zoom
        view.zoomChanged = { value in
            DispatchQueue.main.async { binding.wrappedValue = value }
        }
        if abs(view.magnification - zoom) > 0.001 {
            view.setMagnification(zoom, centeredAt: NSPoint(x: view.contentView.bounds.midX, y: view.contentView.bounds.midY))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selectedText) }
    final class Coordinator: NSObject, ImageAnalysisOverlayViewDelegate {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
            let text = overlayView.selectedText
            DispatchQueue.main.async { [weak self] in self?.selection.wrappedValue = text }
        }
    }
}

private final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        if documentView.frame.width < bounds.width { bounds.origin.x = (documentView.frame.width - bounds.width) / 2 }
        if documentView.frame.height < bounds.height { bounds.origin.y = (documentView.frame.height - bounds.height) / 2 }
        return bounds
    }
}

final class ImageZoomScrollView: NSScrollView {
    let imageContent = LiveTextContainer()
    var zoomChanged: ((Double) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteredImageClipView()
        contentView.drawsBackground = false; drawsBackground = false
        documentView = imageContent
        hasVerticalScroller = true; hasHorizontalScroller = true
        scrollerStyle = .overlay; autohidesScrollers = true
        allowsMagnification = true; minMagnification = 0.25; maxMagnification = 6
        usesPredominantAxisScrolling = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        guard let image = imageContent.imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let viewport = contentView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        if abs(size.width - imageContent.frame.width) > 0.5 || abs(size.height - imageContent.frame.height) > 0.5 {
            imageContent.setFrameSize(size)
            contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
            reflectScrolledClipView(contentView)
        }
    }
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        zoomChanged?(magnification)
    }
    override func scrollWheel(with event: NSEvent) {
        // Wheels zoom; precise two-finger scrolling pans. Pinching uses AppKit magnification.
        if event.scrollingDeltaY != 0 && (!event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.command)) {
            let delta = max(-1, min(1, event.scrollingDeltaY))
            let point = contentView.convert(event.locationInWindow, from: nil)
            setMagnification(magnification * exp(delta * 0.15), centeredAt: point)
            zoomChanged?(magnification)
        } else { super.scrollWheel(with: event) }
    }
}

final class LiveTextContainer: NSView {
    let imageView = NSImageView()
    let overlay = ImageAnalysisOverlayView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        addSubview(imageView); addSubview(overlay)
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .textSelection
        overlay.selectableItemsHighlighted = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        imageView.frame = bounds; overlay.frame = bounds
        overlay.setContentsRectNeedsUpdate()
    }
}
