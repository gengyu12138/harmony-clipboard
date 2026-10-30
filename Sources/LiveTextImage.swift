import AppKit
import SwiftUI
import VisionKit

/// The overlay tracks the same image view at every zoom level, keeping selections on the pixels.
struct LiveTextImage: NSViewRepresentable {
    let image: NSImage
    let analysis: ImageAnalysis?
    @Binding var selectedText: String
    func makeNSView(context: Context) -> LiveTextContainer {
        let view = LiveTextContainer()
        view.overlay.delegate = context.coordinator
        context.coordinator.selection = $selectedText
        return view
    }
    func updateNSView(_ view: LiveTextContainer, context: Context) {
        if view.imageView.image !== image { view.imageView.image = image }
        if view.overlay.analysis !== analysis { view.overlay.analysis = analysis }
        context.coordinator.selection = $selectedText
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
