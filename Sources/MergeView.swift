import SwiftUI

struct TextMergeView: View {
    @ObservedObject var store: ClipboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var records: [Clip] = []
    @State private var selection: [String] = []
    @State private var query = ""
    @State private var separator = MergeSeparator.line
    @State private var draft = ""
    @State private var error = ""
    @State private var copied = false
    private var matching: [Clip] { records.filter { $0.matches(query) } }
    private var usable: Bool { selection.count >= 2 && !draft.isEmpty && draft.utf8.count <= TextMerger.byteLimit }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("合并多条文字").font(.system(size: 20, weight: .semibold))
                Spacer()
                RelayIconButton(title: "关闭合并", symbol: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 18) {
                VStack(spacing: 10) {
                    TextField("搜索文字历史", text: $query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(matching) { clip in
                                Button { toggle(clip.id) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: selection.contains(clip.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(RelayTheme.accent)
                                        Text(clip.title).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                        if let index = selection.firstIndex(of: clip.id) { Text("\(index + 1)").monospacedDigit().foregroundStyle(RelayTheme.muted) }
                                    }.font(.system(size: 12))
                                }.buttonStyle(RelayButtonStyle(selected: selection.contains(clip.id), quiet: true))
                            }
                            if matching.isEmpty { Text("没有匹配的文字历史").font(.system(size: 12)).foregroundStyle(RelayTheme.muted).padding(.top, 32) }
                        }
                    }
                    Text("已选 \(selection.count) / 50 · 按点击顺序合并").font(.system(size: 11)).foregroundStyle(RelayTheme.secondary)
                }.frame(width: 280)
                VStack(spacing: 10) {
                    HStack {
                        Picker("分隔方式", selection: $separator) { ForEach(MergeSeparator.allCases) { Text($0.rawValue).tag($0) } }
                            .frame(width: 200)
                        Spacer()
                        Button("清空选择") { selection = []; rebuild() }.buttonStyle(RelayButtonStyle(quiet: true)).disabled(selection.isEmpty)
                    }
                    ReadableText(text: draft, onChange: { draft = $0 }).accessibilityLabel("合并结果，可直接编辑")
                        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    Text("可直接修改结果；更改勾选或分隔方式会重新生成。").font(.system(size: 11)).foregroundStyle(RelayTheme.muted)
                }
            }
            HStack {
                Text(!error.isEmpty ? error : draft.utf8.count > TextMerger.byteLimit ? "结果超过 256 KB，请精简后复制。" : "\(draft.count) 字符 · 手机同步仍以 16 KB 为限")
                    .font(.system(size: 11)).foregroundStyle(RelayTheme.secondary).lineLimit(2)
                Spacer()
                Button(copied ? "已复制" : "仅复制") { copied = store.copyText(draft) }.buttonStyle(RelayButtonStyle()).disabled(!usable)
                Button("粘贴到原应用") { if store.copyText(draft, paste: true) { dismiss() } }.buttonStyle(RelayButtonStyle(prominent: true)).disabled(!usable)
            }
        }.padding(24).frame(width: 880, height: 530).modifier(GlassShell())
            .onChange(of: separator) { _, _ in rebuild() }
            .onChange(of: draft) { _, _ in copied = false }
            .onAppear { records = store.clips.filter { $0.text?.isEmpty == false }.sorted { $0.date > $1.date } }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.removeAll { $0 == id } }
        else {
            guard selection.count < TextMerger.itemLimit else { error = "一次最多选择 50 条，请先取消部分选择。"; return }
            selection.append(id)
        }
        rebuild()
    }
    private func rebuild() {
        do {
            var texts: [String] = []
            for id in selection {
                guard let text = records.first(where: { $0.id == id })?.text else { throw TextToolError(message: "所选记录不可用，请重新选择。") }
                texts.append(text)
            }
            draft = try TextMerger.combine(texts, separator: separator); error = ""
        } catch { draft = ""; self.error = error.localizedDescription }
    }
}
