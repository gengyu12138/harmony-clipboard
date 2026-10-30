import AppKit
import SwiftUI
import VisionKit

/// Shared by the main panel and expanded preview so both use the original image and text selection.
struct ClipboardImagePreview: View {
    let clip: Clip
    let root: URL
    let pendingData: Data?
    let copyText: (String) -> Bool
    let recognizedText: (String) -> Void
    @State private var image: NSImage?
    @State private var analysis: ImageAnalysis?
    @State private var selectedText = ""
    @State private var zoom = 1.0
    @State private var failed = false
    @State private var recognizing = false
    @State private var recognition = "正在加载图片…"
    @State private var attempt = 0
    @State private var showTranscript = false

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                RelayIconButton(title: "缩小图片", symbol: "minus.magnifyingglass") { zoom = max(0.25, zoom / 1.25) }.disabled(zoom <= 0.25 || image == nil || showTranscript)
                Text("\(Int((zoom * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().frame(width: 42)
                RelayIconButton(title: "放大图片", symbol: "plus.magnifyingglass") { zoom = min(6, zoom * 1.25) }.disabled(zoom >= 6 || image == nil || showTranscript)
                Spacer()
                Button("适应窗口") { zoom = 1; showTranscript = false }.buttonStyle(RelayButtonStyle(quiet: true)).disabled(image == nil)
            }
            Group {
                if showTranscript, let analysis {
                    ReadableText(text: analysis.transcript)
                } else if let image {
                    LiveTextImage(image: image, analysis: analysis, selectedText: $selectedText, zoom: $zoom)
                } else if failed {
                    VStack(spacing: 10) {
                        Text("图片文件不可用").foregroundStyle(RelayTheme.secondary)
                        Button("重新加载") { attempt += 1 }.buttonStyle(RelayButtonStyle())
                    }
                } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 6) {
                if recognizing { ProgressView().controlSize(.mini) }
                Text(recognition).font(.system(size: 10)).foregroundStyle(RelayTheme.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            if let analysis {
                HStack(spacing: 6) {
                    Button(showTranscript ? "回到图片" : "查看全文") { showTranscript.toggle() }.buttonStyle(RelayButtonStyle())
                    Spacer(minLength: 0)
                    Button("复制选中") { if copyText(selectedText) { recognition = "已复制选中文字" } }
                        .buttonStyle(RelayButtonStyle()).disabled(selectedText.isEmpty || showTranscript).accessibilityLabel("复制选中文字")
                    Button("复制全文") { if copyText(analysis.transcript) { recognition = "已复制全部识别文字" } }
                        .buttonStyle(RelayButtonStyle(prominent: true)).disabled(analysis.transcript.isEmpty).accessibilityLabel("复制全部文字")
                }
            } else if image != nil && !recognizing && ImageAnalyzer.isSupported {
                Button("重新识别") { attempt += 1 }.buttonStyle(RelayButtonStyle())
            }
        }.task(id: attempt) {
            image = nil; analysis = nil; selectedText = ""; failed = false
            recognizing = false; showTranscript = false; zoom = 1; recognition = "正在加载图片…"
            guard let file = clip.file else { failed = true; recognition = "记录中没有图片文件"; return }
            let data = pendingData, url = root.appendingPathComponent(file)
            let loaded = await Task.detached(priority: .userInitiated) {
                (data ?? (try? Data(contentsOf: url))).flatMap { NSImage(data: $0) }
            }.value
            guard !Task.isCancelled else { return }
            image = loaded; failed = loaded == nil
            guard let loaded else { recognition = "无法读取图片，可重新加载"; return }
            guard ImageAnalyzer.isSupported else { recognition = "滚轮或双指捏合缩放；此 Mac 不支持实况文本"; return }
            recognizing = true; recognition = "图片已加载，正在本机识别文字…"
            do {
                var configuration = ImageAnalyzer.Configuration([.text])
                let supported = ImageAnalyzer.supportedTextRecognitionLanguages
                configuration.locales = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
                let result = try await ImageAnalyzer().analyze(loaded, orientation: .up, configuration: configuration)
                guard !Task.isCancelled else { return }
                analysis = result; recognizing = false
                recognizedText(result.transcript)
                recognition = result.transcript.isEmpty ? "未识别到文字；滚轮或双指捏合缩放" : "拖选文字按 ⌘C；滚轮 / 双指捏合缩放，双指滑动平移"
            } catch {
                guard !Task.isCancelled else { return }
                recognizing = false; recognition = "识别失败，可重试；仍可缩放和复制图片"
            }
        }
    }
}
