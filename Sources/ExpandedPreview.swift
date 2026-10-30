import AppKit
import SwiftUI

struct ReadableText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.appearance = NSAppearance(named: .darkAqua)
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.font = .systemFont(ofSize: 15); view.textColor = NSColor(white: 0.94, alpha: 1)
        view.textContainerInset = NSSize(width: 18, height: 20)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}

struct ExpandedPreview: View {
    let clip: Clip
    let root: URL
    let pendingData: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var zoom = 1.0
    @State private var failed = false
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(clip.isImage ? "图片放大预览" : "完整文字").font(.system(size: 18, weight: .semibold))
                Spacer()
                if clip.isImage {
                    Slider(value: $zoom, in: 0.25...3).frame(width: 180).accessibilityLabel("图片缩放")
                    Text("\(Int(zoom * 100))%").font(.system(size: 12)).monospacedDigit().frame(width: 50).foregroundStyle(RelayTheme.secondary)
                    Button("适应窗口") { zoom = 1 }.buttonStyle(RelayButtonStyle())
                }
                RelayIconButton(title: "关闭预览", symbol: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Group {
              if clip.isImage {
                if let image {
                    GeometryReader { geometry in
                        let fit = min(geometry.size.width / max(1, image.size.width), geometry.size.height / max(1, image.size.height))
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).resizable().frame(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        }
                    }
                } else if failed { Text("图片文件不可用").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
              } else { ReadableText(text: clip.text ?? "") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(RelayTheme.line, lineWidth: 0.5))
            HStack {
                Text(clip.deviceLabel + " · " + clip.source).lineLimit(1)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file))
                Keycap(text: "Esc")
            }.font(.system(size: 11)).foregroundStyle(RelayTheme.secondary)
        }.padding(22).frame(width: 820, height: 560).modifier(GlassShell())
            .task {
                guard let file = clip.file else { return }
                let data = pendingData, url = root.appendingPathComponent(file)
                let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    (data ?? (try? Data(contentsOf: url))).flatMap { NSImage(data: $0) }
                }.value
                if !Task.isCancelled { image = loaded; failed = loaded == nil }
            }
    }
}
