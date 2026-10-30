import AppKit
import SwiftUI

private struct SnippetRequest: Identifiable {
    let id = UUID()
    let text: String?
}

struct PanelView: View {
    @ObservedObject var store: ClipboardStore
    @FocusState private var searchFocused: Bool
    @State private var deletionID: String?
    @State private var confirmsDeletion = false
    @State private var expandedClip: Clip?
    @State private var editingClip: Clip?
    @State private var snippetRequest: SnippetRequest?
    @State private var merging = false

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            filters
            HStack(spacing: 16) {
                history.frame(width: 326)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 18)
            footer
        }
        .modifier(GlassShell())
        .onAppear { searchFocused = true }
        .onChange(of: store.paused) { _, _ in store.historyPauseChanged() }
        .onChange(of: store.current?.id) { _, _ in store.previewDraft = nil }
        .sheet(isPresented: $store.settingsPresented) {
            SettingsView(store: store).presentationBackground(.clear)
        }
        .sheet(item: $expandedClip) { clip in
            ExpandedPreview(clip: clip, root: store.root, pendingData: store.imageData(for: clip), copyText: { store.copyText($0) }, recognizedText: { store.cacheImageText($0, for: clip.id) }).presentationBackground(.clear)
        }
        .sheet(item: $editingClip) { clip in
            TemporaryEdit(original: clip.text ?? "", copy: { store.copyText($0, paste: $1) }).presentationBackground(.clear)
        }
        .sheet(item: $snippetRequest) { request in
            SnippetsView(snippets: store.snippets, store: store, seed: request.text).presentationBackground(.clear)
        }
        .sheet(isPresented: $merging) { TextMergeView(store: store).presentationBackground(.clear) }
        .onReceive(NotificationCenter.default.publisher(for: .init("FocusClipboardSearch"))) { _ in searchFocused = true }
        .alert("删除这条历史记录？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) { deletionID = nil }
            Button("删除", role: .destructive) { if let deletionID { store.delete(deletionID) }; deletionID = nil }
        } message: { Text("只删除本机历史记录及其图片文件，不会清空 Mac 或手机当前剪贴板。") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 19, weight: .medium)).foregroundStyle(RelayTheme.accent)
            Text("接力剪贴板").font(.system(size: 15, weight: .semibold))
            Text("/  CLIPBOARD").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(RelayTheme.muted)
            Spacer()
            Button { store.settingsPresented = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.privacyPaused ? "pause.circle" : store.online ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(store.privacyPaused || !store.online ? RelayTheme.warning : RelayTheme.accent)
                    Text(store.connection).lineLimit(1)
                }
            }.buttonStyle(RelayButtonStyle()).help(store.connectionDetail + "\n" + store.lastSync)
            RelayIconButton(title: "固定面板", symbol: store.pinned ? "pin.fill" : "pin", selected: store.pinned) { store.pinned.toggle() }
            privacyMenu
            moreMenu
            RelayIconButton(title: "设置", symbol: "slider.horizontal.3") { store.configurePhone?() }
            RelayIconButton(title: "收起面板", symbol: "xmark") { store.dismiss?() }
        }.padding(.horizontal, 22).frame(height: 62)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(RelayTheme.secondary)
                TextField("搜索文字、图片文字、来源…", text: $store.query).textFieldStyle(.plain)
                    .font(.system(size: 14)).focused($searchFocused).accessibilityLabel("搜索剪贴板")
                    .help("搜索已识别的图片文字；旧缓存可能被回收，重新打开图片可重建索引。未打开的图片不会自动扫描。")
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(RelayTheme.muted).accessibilityLabel("清空搜索")
                }
                Keycap(text: "⌘F")
            }.padding(.horizontal, 13).frame(height: 42)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(searchFocused ? RelayTheme.accent.opacity(0.60) : RelayTheme.line, lineWidth: 1))
            Button { store.phone("get") } label: { Label("取手机文字", systemImage: "arrow.down.doc").frame(height: 10) }
                .buttonStyle(RelayButtonStyle()).disabled(store.busy || store.privacyPaused)
                .help("读取手机当前文字并加入历史")
            Button { store.phone("capture") } label: { Label("手机截图", systemImage: "camera").frame(height: 10) }
                .buttonStyle(RelayButtonStyle()).disabled(store.busy || store.privacyPaused)
                .help("截取手机当前屏幕并加入历史")
        }.padding(.horizontal, 22).padding(.bottom, 12)
    }

    private var filters: some View {
        HStack(spacing: 3) {
            ForEach(["全部", "文字", "图片", "收藏"], id: \.self) { category in
                Button { store.filter = category; store.selected = store.visible.first?.id } label: {
                    Text(category).frame(minWidth: 34)
                }.buttonStyle(RelayButtonStyle(selected: store.filter == category, quiet: true))
                    .accessibilityAddTraits(store.filter == category ? .isSelected : [])
            }
            Spacer()
            Button { snippetRequest = SnippetRequest(text: nil) } label: { Label("常用片段", systemImage: "square.stack") }
                .buttonStyle(RelayButtonStyle(quiet: true))
            Text("\(store.visible.count) 条").font(.system(size: 11)).foregroundStyle(RelayTheme.muted)
            Rectangle().fill(RelayTheme.line).frame(width: 1, height: 14).padding(.horizontal, 9)
            Menu {
                ForEach(["全部设备", "Mac", "手机"], id: \.self) { device in
                    Button { store.deviceFilter = device; store.selected = store.visible.first?.id } label: {
                        if device == store.deviceFilter { Label(device, systemImage: "checkmark") } else { Text(device) }
                    }
                }
            } label: {
                Label(store.deviceFilter, systemImage: "laptopcomputer.and.iphone").font(.system(size: 12))
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(RelayTheme.secondary).accessibilityLabel("筛选设备")
        }.padding(.horizontal, 22).padding(.bottom, 13)
    }

    private var privacyMenu: some View {
        Menu {
            if store.privacyPaused { Button("恢复记录与同步") { store.resumePrivacy() } }
            else {
                Button("隐私暂停 15 分钟") { store.setPrivacy(minutes: 15) }
                Button("隐私暂停 1 小时") { store.setPrivacy(minutes: 60) }
                Button("暂停直到手动恢复") { store.setPrivacy(minutes: nil) }
            }
        } label: {
            Image(systemName: store.privacyPaused ? "hand.raised.fill" : "hand.raised")
                .foregroundStyle(store.privacyPaused ? RelayTheme.warning : RelayTheme.secondary).frame(width: 20, height: 32)
        }.menuStyle(.borderlessButton).fixedSize().help("隐私暂停").accessibilityLabel("隐私暂停")
    }

    private var moreMenu: some View {
        Menu {
            Button("合并多条文字…") { merging = true }.disabled(store.clips.filter { $0.text?.isEmpty == false }.count < 2)
            Divider()
            Toggle("暂停历史记录", isOn: $store.paused)
            Button("启动手机同步") { store.phone("start") }.disabled(store.busy)
            Button("停止手机同步") { store.phone("stop") }.disabled(store.busy)
            Button("打开历史存储目录") { NSWorkspace.shared.open(store.root) }
            Divider()
            Text("本机历史最多 \(store.preferences.count) 条 / \(store.preferences.megabytes) MB")
            Text("单条最多 20 MB · 文字发送最多 16 KB")
            Divider()
            Button("退出接力剪贴板") { NSApp.terminate(nil) }
        } label: { Image(systemName: "ellipsis").frame(width: 20, height: 32) }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(RelayTheme.secondary).accessibilityLabel("更多")
    }

    private var history: some View {
        let records = store.visible
        let selectedID = records.first(where: { $0.id == store.selected })?.id ?? records.first?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if records.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: store.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 28, weight: .light))
                            Text(store.query.isEmpty ? "从一次复制开始" : "没有找到匹配内容").font(.system(size: 14, weight: .medium))
                            Text(store.query.isEmpty ? "新复制的文字和图片会出现在这里" : "试试其他关键词，或切换类型与设备筛选")
                                .font(.system(size: 12)).multilineTextAlignment(.center)
                        }.foregroundStyle(RelayTheme.secondary).padding(.horizontal, 20).frame(maxWidth: .infinity).padding(.top, 64)
                    }
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, clip in
                        historyRow(clip, index: index, selected: selectedID == clip.id).id(clip.id)
                    }
                }.padding(.trailing, 4)
            }.onChange(of: store.selected) { _, value in if let value { proxy.scrollTo(value) } }
        }
    }

    private func historyRow(_ clip: Clip, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05))
                if clip.isImage {
                    HistoryThumbnail(clip: clip, store: store).padding(3)
                } else {
                    Image(systemName: clip.isImage ? "photo" : "text.alignleft").foregroundStyle(RelayTheme.secondary)
                }
            }.frame(width: 32, height: 38).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(clip.title).font(.system(size: 13, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(clip.deviceLabel).lineLimit(1)
                    Text("·")
                    Text(clip.date, style: .relative).lineLimit(1)
                    if clip.favorite { Image(systemName: "star.fill").foregroundStyle(RelayTheme.accent) }
                    if clip.pinnedAt != nil { Image(systemName: "pin.fill").foregroundStyle(RelayTheme.accent).accessibilityLabel("已置顶") }
                }.font(.system(size: 10)).foregroundStyle(RelayTheme.muted)
            }
            VStack(spacing: 4) {
                if index < 9 { Text("⌘\(index + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(RelayTheme.muted) }
                if !clip.isImage {
                    Button { store.selected = clip.id; store.phone("send") } label: {
                        Image(systemName: "paperplane").font(.system(size: 12)).frame(width: 26, height: 26)
                    }.buttonStyle(.plain).foregroundStyle(RelayTheme.accent).disabled(store.busy || store.privacyPaused)
                        .help("发送这条文字到手机剪贴板").accessibilityLabel("发送这条文字到手机")
                }
            }.frame(width: 26)
        }.padding(.horizontal, 11).padding(.vertical, 10).frame(minHeight: 70)
            .modifier(RelayRow(selected: selected)).contentShape(Rectangle())
            .onTapGesture(count: 2) { store.selected = clip.id; store.copySelected(close: true) }
            // Immediate selection must not wait for the double-click interval.
            .simultaneousGesture(TapGesture().onEnded { store.selected = clip.id })
            .accessibilityElement(children: .contain).accessibilityLabel(clip.title).accessibilityAddTraits(.isButton)
            .accessibilityAction { store.selected = clip.id }
            .contextMenu {
                Button(clip.pinnedAt == nil ? "置顶" : "取消置顶") { store.togglePin(clip.id) }
                Button("复制") { store.selected = clip.id; store.copySelected() }
                if let text = clip.imageText, !text.isEmpty { Button("复制图片识别文字") { _ = store.copyText(text) } }
                if let text = clip.text {
                    Button("存为常用片段") { snippetRequest = SnippetRequest(text: text) }
                    Button("编辑后粘贴") { editingClip = clip }
                }
                Button("删除记录", role: .destructive) { deletionID = clip.id; confirmsDeletion = true }
            }
    }

    private var preview: some View {
        let selectedClip = store.current
        let hasContent = selectedClip.map { $0.isImage || !store.previewText(for: $0).isEmpty } ?? false
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(selectedClip?.isImage == true ? "图片预览" : "内容预览").font(.system(size: 12, weight: .medium)).foregroundStyle(RelayTheme.secondary)
                Spacer()
                if let clip = selectedClip, clip.text != nil {
                    RelayIconButton(title: "存为常用片段", symbol: "text.badge.plus") { snippetRequest = SnippetRequest(text: store.previewText(for: clip)) }
                }
                RelayIconButton(title: "置顶所选记录", symbol: selectedClip?.pinnedAt == nil ? "pin" : "pin.fill", selected: selectedClip?.pinnedAt != nil) {
                    if let id = selectedClip?.id { store.togglePin(id) }
                }.disabled(selectedClip == nil)
                RelayIconButton(title: "收藏所选内容", symbol: selectedClip?.favorite == true ? "star.fill" : "star", selected: selectedClip?.favorite == true) { store.favoriteSelected() }.disabled(selectedClip == nil)
                RelayIconButton(title: "展开预览", symbol: "arrow.up.left.and.arrow.down.right") {
                    guard var clip = selectedClip else { return }
                    if clip.text != nil {
                        let text = store.previewText(for: clip)
                        clip.text = text; clip.bytes = text.utf8.count
                    }
                    expandedClip = clip
                }.disabled(selectedClip == nil)
                RelayIconButton(title: "删除所选记录", symbol: "trash", destructive: true) { deletionID = selectedClip?.id; confirmsDeletion = true }.disabled(selectedClip == nil)
            }.padding(14)
            Rectangle().fill(RelayTheme.line).frame(height: 0.5).padding(.horizontal, 16)
            if let clip = selectedClip {
                if clip.isImage {
                    ClipboardImagePreview(clip: clip, root: store.root, pendingData: store.imageData(for: clip), copyText: { store.copyText($0) }, recognizedText: { store.cacheImageText($0, for: clip.id) })
                        .id(clip.id).padding(12)
                } else {
                    VStack(spacing: 4) {
                        ReadableText(text: store.previewText(for: clip), onChange: {
                            store.previewDraft = (clip.id, $0)
                        }).id(clip.id).accessibilityLabel("预览文字，可直接编辑")
                        HStack {
                            Text("\(store.previewText(for: clip).count) 字符 · 临时编辑").font(.system(size: 10)).foregroundStyle(RelayTheme.muted)
                            Spacer()
                            Menu("整理文字") {
                                ForEach(TextTransform.allCases) { action in
                                    Button(action.rawValue) { store.previewDraft = (clip.id, action.apply(to: store.previewText(for: clip))) }
                                }
                            }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).accessibilityLabel("整理预览文字")
                            if store.previewDraft?.id == clip.id {
                                Button("还原") { store.previewDraft = nil }.buttonStyle(RelayButtonStyle(quiet: true))
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 8)
                    }.frame(maxHeight: .infinity)
                }
                HStack {
                    Label(clip.deviceLabel + " · " + clip.source, systemImage: clip.isImage ? "photo" : "text.alignleft").lineLimit(1)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file))
                }.font(.system(size: 10)).foregroundStyle(RelayTheme.muted).padding(.horizontal, 18).padding(.bottom, 12)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(RelayTheme.accent)
                    Text("选一条内容，接着用").font(.system(size: 16, weight: .medium))
                    Text("预览、复制，再粘贴到正在使用的应用").font(.system(size: 12)).foregroundStyle(RelayTheme.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(RelayTheme.line).frame(height: 0.5)
            HStack(spacing: 8) {
                Button { store.copySelected() } label: { Label("复制", systemImage: "doc.on.doc") }.buttonStyle(RelayButtonStyle())
                    .help("复制到 Mac 剪贴板").disabled(!hasContent)
                Button { store.copySelected(close: true, plainText: true) } label: { Text("纯文本粘贴") }.buttonStyle(RelayButtonStyle())
                    .help("Shift+回车").disabled(!hasContent || selectedClip?.isImage == true)
                Spacer()
                Button { store.copySelected(close: true) } label: {
                    HStack(spacing: 12) { Text("粘贴"); Image(systemName: "return") }
                }.buttonStyle(RelayButtonStyle(prominent: true)).help("粘贴到呼出面板前的应用").disabled(!hasContent)
            }.padding(14)
        }.background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(RelayTheme.line, lineWidth: 0.5))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if store.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: store.privacyPaused || store.paused ? "pause.circle" : "lock.shield").foregroundStyle(store.privacyPaused || store.paused ? RelayTheme.warning : RelayTheme.muted) }
            Text(!store.hotkeyAvailable ? "快捷键已被占用，请在设置中更换" : store.privacyPaused ? store.privacyLabel : store.paused ? "历史记录已暂停，文字同步仍可运行" : store.message)
                .font(.system(size: 11)).foregroundStyle(RelayTheme.secondary).lineLimit(1).help(store.message)
            Spacer(minLength: 8)
            Keycap(text: "↑↓"); Text("选择").font(.system(size: 10)).foregroundStyle(RelayTheme.muted)
            Keycap(text: store.preferences.shortcutLabel)
        }.padding(.horizontal, 23).frame(height: 46)
    }
}

private struct HistoryThumbnail: View {
    let clip: Clip
    let store: ClipboardStore
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(RelayTheme.muted).help("图片文件不可用") }
            else { ProgressView().controlSize(.mini) }
        }.task(id: clip.id) {
            let loaded = await store.loadThumbnail(for: clip)
            guard !Task.isCancelled else { return }
            image = loaded; failed = loaded == nil
        }
    }
}
