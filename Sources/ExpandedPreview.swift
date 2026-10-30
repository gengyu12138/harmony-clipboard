import AppKit
import SwiftUI
import VisionKit

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
    let copyText: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var zoom = 1.0
    @State private var failed = false
    @State private var analysis: ImageAnalysis?
    @State private var selectedText = ""
    @State private var recognition = "正在本机识别文字…"
    @State private var recognizing = false
    @State private var attempt = 0
    @State private var showTranscript = false
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(clip.isImage ? "图片与实况文本" : "完整文字").font(.system(size: 18, weight: .semibold))
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
                if showTranscript, let analysis {
                    ReadableText(text: analysis.transcript)
                } else if let image {
                    GeometryReader { geometry in
                        let fit = min(geometry.size.width / max(1, image.size.width), geometry.size.height / max(1, image.size.height))
                        ScrollView([.horizontal, .vertical]) {
                            LiveTextImage(image: image, analysis: analysis, selectedText: $selectedText)
                                .frame(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
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
            if clip.isImage {
                HStack(spacing: 8) {
                    if recognizing { ProgressView().controlSize(.small) }
                    Text(recognition).font(.system(size: 11)).foregroundStyle(RelayTheme.secondary).lineLimit(2)
                    Spacer()
                    if analysis != nil {
                        Button(showTranscript ? "回到图片" : "查看全文") { showTranscript.toggle() }.buttonStyle(RelayButtonStyle())
                        Button("复制选中文字") { if copyText(selectedText) { recognition = "已复制选中文字" } }.buttonStyle(RelayButtonStyle()).disabled(selectedText.isEmpty || showTranscript)
                        Button("复制全部文字") { if let text = analysis?.transcript, copyText(text) { recognition = "已复制全部识别文字" } }.buttonStyle(RelayButtonStyle(prominent: true)).disabled(analysis?.transcript.isEmpty != false)
                    } else if !recognizing && image != nil && ImageAnalyzer.isSupported {
                        Button("重新识别") { attempt += 1 }.buttonStyle(RelayButtonStyle())
                    }
                }
            }
            HStack {
                Text(clip.deviceLabel + " · " + clip.source).lineLimit(1)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file))
                Keycap(text: "Esc")
            }.font(.system(size: 11)).foregroundStyle(RelayTheme.secondary)
        }.padding(22).frame(width: 820, height: 560).modifier(GlassShell())
            .task(id: attempt) {
                guard let file = clip.file else { return }
                let data = pendingData, url = root.appendingPathComponent(file)
                let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    (data ?? (try? Data(contentsOf: url))).flatMap { NSImage(data: $0) }
                }.value
                guard !Task.isCancelled else { return }
                image = loaded; failed = loaded == nil
                guard let loaded else { recognition = "图片文件不可用"; return }
                guard ImageAnalyzer.isSupported else { recognition = "这台 Mac 不支持系统实况文本"; return }
                recognizing = true; analysis = nil; selectedText = ""; recognition = "正在本机识别文字…"
                do {
                    var configuration = ImageAnalyzer.Configuration([.text])
                    let supported = ImageAnalyzer.supportedTextRecognitionLanguages
                    configuration.locales = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
                    let result = try await ImageAnalyzer().analyze(loaded, orientation: .up, configuration: configuration)
                    guard !Task.isCancelled else { return }
                    analysis = result; recognizing = false
                    recognition = result.transcript.isEmpty ? "未识别到文字，试试更清晰的原图" : "在图片文字上拖动选择，按 ⌘C 复制"
                } catch {
                    guard !Task.isCancelled else { return }
                    recognizing = false; recognition = "识别失败，可重试；原图仍可查看"
                }
            }
    }
}
