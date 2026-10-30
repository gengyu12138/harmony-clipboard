import AppKit
import SwiftUI

struct ReadableText: NSViewRepresentable {
    let text: String
    var onChange: ((String) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.appearance = NSAppearance(named: .darkAqua)
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = onChange != nil; view.isSelectable = true; view.drawsBackground = false
        view.isRichText = false; view.allowsUndo = true; view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 15); view.textColor = NSColor(white: 0.94, alpha: 1)
        view.textContainerInset = NSSize(width: 18, height: 20)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: ((String) -> Void)?
        init(onChange: ((String) -> Void)?) { self.onChange = onChange }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onChange?(view.string)
        }
    }
}

struct ExpandedPreview: View {
    let clip: Clip
    let root: URL
    let pendingData: Data?
    let copyText: (String) -> Bool
    let recognizedText: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(clip.isImage ? "图片与实况文本" : "完整文字").font(.system(size: 18, weight: .semibold))
                Spacer()
                RelayIconButton(title: "关闭预览", symbol: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Group {
              if clip.isImage {
                ClipboardImagePreview(clip: clip, root: root, pendingData: pendingData, copyText: copyText, recognizedText: recognizedText).id(clip.id).padding(12)
              } else { ReadableText(text: clip.text ?? "") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(RelayTheme.line, lineWidth: 0.5))
            HStack {
                Text(clip.deviceLabel + " · " + clip.source).lineLimit(1)
                Text(clip.date, format: .dateTime.year().month().day().hour().minute().second()).lineLimit(1)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file))
                Keycap(text: "Esc")
            }.font(.system(size: 11)).foregroundStyle(RelayTheme.secondary)
        }.padding(22).frame(width: 820, height: 560).modifier(GlassShell())
    }
}
