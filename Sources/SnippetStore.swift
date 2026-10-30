import AppKit
import Combine
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
            try JSONEncoder().encode(library).write(to: url, options: .atomic)
            self.library = library; error = ""
            return true
        } catch { self.error = "保存失败，原片段保留：\(error.localizedDescription)"; return false }
    }

    @discardableResult
    func exportBackupFile(to destination: URL) -> Bool {
        guard writable else { return false }
        do {
            let active = url.resolvingSymlinksInPath().standardizedFileURL
            let target = destination.resolvingSymlinksInPath().standardizedFileURL
            let failure = TextToolError(message: "不能将备份覆盖到正在使用的片段库，请选择另一个文件。")
            guard destination.isFileURL, target != active else { throw failure }
            let manager = FileManager.default
            if manager.fileExists(atPath: active.path), manager.fileExists(atPath: target.path) {
                // File identity also protects hard links and alternate casing on the same volume.
                let original = try manager.attributesOfItem(atPath: active.path)
                let selected = try manager.attributesOfItem(atPath: target.path)
                guard let originalDevice = original[.systemNumber] as? NSNumber,
                      let originalFile = original[.systemFileNumber] as? NSNumber,
                      let selectedDevice = selected[.systemNumber] as? NSNumber,
                      let selectedFile = selected[.systemFileNumber] as? NSNumber else {
                    throw TextToolError(message: "无法确认目标文件身份，未导出备份。")
                }
                guard originalDevice != selectedDevice || originalFile != selectedFile else { throw failure }
            }
            try SnippetBackupCodec.encode(library).write(to: destination, options: .atomic)
            error = ""; return true
        } catch { self.error = "导出失败：\(error.localizedDescription)"; return false }
    }

    func importBackupFile(from source: URL) -> (items: Int, groups: Int)? {
        guard writable else { return nil }
        do {
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= SnippetBackupCodec.fileLimit else { throw TextToolError(message: "备份文件过大或大小不可读，未导入。") }
            let incoming = try SnippetBackupCodec.decode(Data(contentsOf: source, options: .mappedIfSafe))
            let merged = try SnippetBackupCodec.merge(incoming, into: library)
            guard save(merged.library) else { return nil }
            return (merged.items, merged.groups)
        } catch { self.error = "导入失败，原片段保留：\(error.localizedDescription)"; return nil }
    }

    func exportBackup(completion: @escaping (String) -> Void) {
        guard writable else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "接力剪贴板-常用片段.json"
        panel.message = "明文 JSON 备份，仅包含常用片段和分组，请妥善保管。"; panel.prompt = "导出备份"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            if self.exportBackupFile(to: url) { completion("常用片段已导出") }
        }
    }

    func importBackup(completion: @escaping (String) -> Void) {
        guard writable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "合并加入片段库，现有内容保留；同组同标题同内容的片段跳过。"; panel.prompt = "合并导入"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            if let result = self.importBackupFile(from: url) { completion("已导入 \(result.items) 条片段、\(result.groups) 个分组；重复内容已跳过") }
        }
    }
}
