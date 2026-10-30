import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class SnippetStore: ObservableObject {
    @Published private(set) var library = SnippetLibrary()
    @Published var error = ""
    private var writable = true
    private let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("snippets.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let loaded = try JSONDecoder().decode(SnippetLibrary.self, from: Data(contentsOf: url))
                try SnippetBackupCodec.validate(loaded)
                library = loaded
            }
        } catch { writable = false; self.error = "片段库读取失败，原文件保留，暂不允许覆盖。" }
    }

    @discardableResult
    func save(_ library: SnippetLibrary) -> Bool {
        guard writable else { return false }
        do {
            try SnippetBackupCodec.validate(library)
            let data = try JSONEncoder().encode(library)
            try data.write(to: url, options: .atomic)
            self.library = library; error = ""
            return true
        } catch { self.error = "保存失败，原片段保留：\(error.localizedDescription)"; return false }
    }

    func exportBackup(completion: @escaping (String) -> Void) {
        guard writable else { return }
        let data: Data
        do { data = try SnippetBackupCodec.encode(library) }
        catch { self.error = error.localizedDescription; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "接力剪贴板-常用片段.json"
        panel.message = "明文 JSON 备份，仅包含常用片段和分组，请妥善保管。"; panel.prompt = "导出备份"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); self?.error = ""; completion("常用片段已导出") }
            catch { self?.error = "导出失败：\(error.localizedDescription)" }
        }
    }

    func importBackup(completion: @escaping (String) -> Void) {
        guard writable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "合并加入片段库，现有内容保留；同组同标题同内容的片段跳过。"; panel.prompt = "合并导入"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size, size <= SnippetBackupCodec.fileLimit else { throw TextToolError(message: "备份文件过大或大小不可读，未导入。") }
                let incoming = try SnippetBackupCodec.decode(Data(contentsOf: url, options: .mappedIfSafe))
                let merged = try SnippetBackupCodec.merge(incoming, into: self.library)
                if self.save(merged.library) { completion("已导入 \(merged.items) 条片段、\(merged.groups) 个分组；重复内容已跳过") }
            } catch { self.error = "导入失败，原片段保留：\(error.localizedDescription)" }
        }
    }
}

struct TemporaryEdit: View {
    let original: String
    let copy: (String, Bool) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("编辑后粘贴").font(.system(size: 20, weight: .semibold))
                Spacer()
                RelayIconButton(title: "取消编辑", symbol: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("仅修改本次使用的文字，不覆盖原历史或常用片段。").font(.system(size: 12)).foregroundStyle(RelayTheme.secondary)
            TextEditor(text: $text).font(.system(size: 15)).scrollContentBackground(.hidden)
                .padding(12).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("临时编辑内容")
            HStack {
                Text(failed ? "复制失败，请重试" : "\(text.count) 字符").font(.system(size: 12)).foregroundStyle(RelayTheme.secondary)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(RelayButtonStyle())
                Button("仅复制") { finish(paste: false) }.buttonStyle(RelayButtonStyle()).disabled(text.isEmpty)
                Button("粘贴到原应用") { finish(paste: true) }.buttonStyle(RelayButtonStyle(prominent: true)).disabled(text.isEmpty)
            }
        }.padding(24).frame(width: 700, height: 470).modifier(GlassShell()).onAppear { text = original }
    }
    private func finish(paste: Bool) {
        // The store delays paste until dismissal and cancels if the clipboard changes meanwhile.
        if copy(text, paste) {
            dismiss()
        } else { failed = true }
    }
}

struct SnippetsView: View {
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var store: ClipboardStore
    let seed: String?
    @Environment(\.dismiss) private var dismiss
    @State private var groupID: String?
    @State private var allGroups = true
    @State private var selected: String?
    @State private var draft = Snippet(title: "", text: "")
    @State private var query = ""
    @State private var groupDraft: SnippetGroup?
    @State private var deleteKind: String?
    @State private var confirmDelete = false
    @State private var editing: Clip?
    @State private var notice = ""
    private var original: Snippet? { snippets.library.items.first { $0.id == selected } }
    private var dirty: Bool { original.map { $0 != draft } ?? (!draft.text.isEmpty || !draft.title.isEmpty) }
    private var items: [Snippet] {
        snippets.library.items.filter { (allGroups || $0.groupID == groupID) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("常用片段").font(.system(size: 20, weight: .semibold))
                Text("单独保存 · 不随历史清理").font(.system(size: 12)).foregroundStyle(RelayTheme.secondary)
                Spacer()
                Menu("备份") {
                    Button("导出备份…") { snippets.exportBackup { notice = $0 } }
                    Button("合并导入…") { snippets.importBackup { notice = $0 } }
                }.menuStyle(.borderlessButton).fixedSize().disabled(dirty).accessibilityLabel("常用片段备份")
                Button("新建片段") { selected = nil; draft = Snippet(groupID: groupID, title: "", text: "") }.buttonStyle(RelayButtonStyle()).disabled(dirty)
                RelayIconButton(title: "关闭片段库", symbol: "xmark") { dismiss() }.disabled(dirty)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Button { allGroups = true; groupID = nil; selected = nil; draft = Snippet(title: "", text: ""); query = "" } label: {
                        Label("全部片段", systemImage: "square.stack").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(RelayButtonStyle(selected: allGroups, quiet: true)).disabled(dirty)
                    groupButton("未分组", id: nil)
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(snippets.library.groups) { group in groupButton(group.name, id: group.id) }
                        }
                    }
                    Button("新建分组") { groupDraft = SnippetGroup(name: "") }.buttonStyle(RelayButtonStyle()).disabled(dirty)
                    if !allGroups && groupID != nil {
                        Button("重命名分组") { groupDraft = snippets.library.groups.first { $0.id == groupID } }.buttonStyle(RelayButtonStyle()).disabled(dirty)
                        Button("删除分组") { deleteKind = "group"; confirmDelete = true }.buttonStyle(RelayButtonStyle(destructive: true)).disabled(dirty)
                    }
                }.frame(width: 140)
                VStack(spacing: 10) {
                    TextField(allGroups ? "搜索全部片段" : "搜索当前分组", text: $query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(items) { item in
                                Button { selected = item.id; draft = item } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(item.text).font(.system(size: 11)).foregroundStyle(RelayTheme.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(RelayButtonStyle(selected: item.id == selected, quiet: true)).disabled(dirty)
                            }
                            if items.isEmpty { Text(query.isEmpty ? "还没有常用片段" : "没有匹配的片段").font(.system(size: 12)).foregroundStyle(RelayTheme.muted).padding(.top, 30) }
                        }
                    }
                }.frame(width: 200)
                VStack(alignment: .leading, spacing: 12) {
                    TextField("片段标题", text: $draft.title).textFieldStyle(.roundedBorder).accessibilityLabel("片段标题")
                    Picker("分组", selection: $draft.groupID) {
                        Text("未分组").tag(String?.none)
                        ForEach(snippets.library.groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextEditor(text: $draft.text).scrollContentBackground(.hidden).padding(10)
                        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("片段内容")
                    HStack {
                        if dirty {
                            Button("放弃修改") { draft = original ?? Snippet(groupID: groupID, title: "", text: "") }.buttonStyle(RelayButtonStyle())
                        } else if selected != nil {
                            RelayIconButton(title: "删除片段", symbol: "trash", destructive: true) { deleteKind = "item"; confirmDelete = true }
                        }
                        Spacer()
                        Button("保存片段") { saveSnippet() }.buttonStyle(RelayButtonStyle(prominent: true)).disabled(!dirty || draft.text.isEmpty || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack {
                        Button("复制") { if store.copyText(draft.text) { notice = "已复制" } }.buttonStyle(RelayButtonStyle()).disabled(draft.text.isEmpty)
                        Button("临时编辑") { editing = Clip(id: draft.id, text: draft.text, source: "常用片段", date: Date(), bytes: draft.text.utf8.count) }.buttonStyle(RelayButtonStyle()).disabled(draft.text.isEmpty || dirty)
                        Spacer()
                        Button("粘贴") { pasteSnippet() }.buttonStyle(RelayButtonStyle(prominent: true)).disabled(draft.text.isEmpty || dirty)
                    }
                }
            }
            HStack {
                Text(!snippets.error.isEmpty ? snippets.error : dirty ? "有未保存的修改，请保存或放弃后切换。" : notice.isEmpty ? "文字片段最多 64 KB，片段库最多 2 MB；仅保存在本机。" : notice)
                    .font(.system(size: 11)).foregroundStyle(RelayTheme.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 920, height: 560).modifier(GlassShell())
            .interactiveDismissDisabled(dirty)
            .onExitCommand { if !dirty { dismiss() } }
            .onAppear { if let seed { draft.text = seed; draft.title = String(seed.prefix(24)).replacingOccurrences(of: "\n", with: " ") } }
            .sheet(item: $editing) { clip in TemporaryEdit(original: clip.text ?? "", copy: { text, paste in
                let copied = store.copyText(text, paste: paste)
                if copied && paste { dismiss() }
                return copied
            }) }
            .sheet(item: $groupDraft) { group in
                SnippetGroupEditor(group: group, snippets: snippets) { saveGroup(id: group.id, name: $0) }
            }
            .alert(deleteKind == "group" ? "删除这个分组？" : "删除这个片段？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { deleteSelection() }
            } message: { Text(deleteKind == "group" ? "片段会移到“未分组”，内容保留。" : "仅删除常用片段，原历史不受影响；删除后无法撤销。") }
    }
    private func groupButton(_ title: String, id: String?) -> some View {
        Button { allGroups = false; groupID = id; selected = nil; draft = Snippet(groupID: id, title: "", text: ""); query = "" } label: {
            Label(title, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
        }.buttonStyle(RelayButtonStyle(selected: !allGroups && groupID == id, quiet: true)).disabled(dirty)
    }
    private func saveSnippet() {
        guard draft.text.utf8.count <= 64 * 1024 else { snippets.error = "单个片段最多 64 KB。"; return }
        var value = snippets.library
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = value.items.firstIndex(where: { $0.id == draft.id }) { value.items[index] = draft }
        else { value.items.insert(draft, at: 0) }
        if snippets.save(value) { selected = draft.id; groupID = draft.groupID; notice = "片段已保存" }
    }
    private func saveGroup(id: String, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !snippets.library.groups.contains(where: { $0.name == name && $0.id != id }) else { snippets.error = "分组名称为空或已存在。"; return false }
        var value = snippets.library
        if let index = value.groups.firstIndex(where: { $0.id == id }) { value.groups[index].name = name }
        else { value.groups.append(SnippetGroup(id: id, name: name)) }
        return snippets.save(value)
    }
    private func deleteSelection() {
        var value = snippets.library
        if deleteKind == "group", let groupID {
            value.groups.removeAll { $0.id == groupID }
            for index in value.items.indices where value.items[index].groupID == groupID { value.items[index].groupID = nil }
        } else { value.items.removeAll { $0.id == selected } }
        if snippets.save(value) { if deleteKind == "group" { groupID = nil }; selected = nil; draft = Snippet(groupID: groupID, title: "", text: "") }
    }
    private func pasteSnippet() {
        let text = draft.text
        guard store.copyText(text, paste: true) else { return }
        dismiss()
    }
}

private struct SnippetGroupEditor: View {
    let group: SnippetGroup
    @ObservedObject var snippets: SnippetStore
    let save: (String) -> Bool
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(group.name.isEmpty ? "新建分组" : "重命名分组").font(.system(size: 18, weight: .semibold))
            TextField("分组名称", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("分组名称")
            Text(snippets.error.isEmpty ? "名称不能为空或与已有分组重复。" : snippets.error)
                .font(.system(size: 12)).foregroundStyle(RelayTheme.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(RelayButtonStyle()).keyboardShortcut(.cancelAction)
                Button("保存") { if save(name) { dismiss() } }.buttonStyle(RelayButtonStyle(prominent: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 380).modifier(GlassShell()).onAppear { name = group.name }
    }
}
