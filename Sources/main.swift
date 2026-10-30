import AppKit
import SwiftUI
import Carbon
import CryptoKit
import ApplicationServices
import ImageIO

struct Clip: Codable, Identifiable {
    var id: String
    var text: String?
    var file: String?
    var mime: String?
    var source: String
    var date: Date
    var bytes: Int
    var favorite = false
    var pinnedAt: Date? = nil
    var devices: [String]? = nil
    var isImage: Bool { file != nil }
    var recordedDevices: [String] { devices ?? (["鸿蒙手机", "手机截图"].contains(source) ? ["手机"] : ["Mac"]) }
    var deviceLabel: String { recordedDevices.joined(separator: " · ") }
    var title: String { text.map { String($0.prefix(180)).replacingOccurrences(of: "\n", with: " ") } ?? "图片 · \(source)" }
}

final class ClipboardStore: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var selected: String?
    @Published var query = ""
    @Published var filter = "全部"
    @Published var deviceFilter = "全部设备"
    @Published var pinned = false
    @Published var paused = false
    @Published var privacyPaused = false
    @Published var privacyLabel = ""
    @Published var preferences = PanelPreferences.load()
    @Published var panelAutostart: Bool?
    @Published var syncAutostart: Bool?
    @Published var lastSync = "尚无同步记录"
    @Published var connectionDetail = ""
    @Published var settingsPresented = false
    @Published var imageRevision = 0
    @Published var applicationExcluded = false
    let exclusions = ExclusionStore()
    lazy var snippets = SnippetStore(root: root)
    private var exclusionObserver: NSObjectProtocol?
    private var exclusionStamp = ""
    var changeHotkey: ((PanelPreferences) -> Bool)?
    private var privacyGeneration = UUID()
    private var skipPhoneBaseline = false
    private let io = DispatchQueue(label: "clipboard.history.io", qos: .utility)
    private let processing = DispatchQueue(label: "clipboard.images", qos: .userInitiated)
    private var saveWork: DispatchWorkItem?
    private var saveVersion = 0
    private var pendingImages: [String: Data] = [:]
    private var pendingDeletes: Set<String> = []
    private var loadingImages: Set<String> = []
    @Published var busy = false
    @Published var message = "复制后自动记录 · 仅保存在本机"
    @Published var online = false
    @Published var connection = "检查手机连接…"
    @Published var hotkeyAvailable = true
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HarmonyClipboardPanel")
    private var lastCount = -1
    private var timer: Timer?
    private var tick = 0
    private var historyWritable = true
    private var phoneReading = false
    private var lastPhoneText: String?
    private let imageCache = NSCache<NSString, NSImage>()
    var dismiss: (() -> Void)?
    var paste: (() -> Void)?
    var configurePhone: (() -> Void)?
    var visible: [Clip] {
        clips.filter {
            (filter == "全部" || filter == "文字" && !$0.isImage || filter == "图片" && $0.isImage || filter == "收藏" && $0.favorite)
            && (deviceFilter == "全部设备" || $0.recordedDevices.contains(deviceFilter))
            && (query.isEmpty || ($0.text ?? $0.title).localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query))
        }.sorted {
            if let left = $0.pinnedAt, let right = $1.pinnedAt { return left > right }
            if ($0.pinnedAt != nil) != ($1.pinnedAt != nil) { return $0.pinnedAt != nil }
            return $0.date > $1.date
        }
    }
    var current: Clip? { visible.first(where: { $0.id == selected }) ?? visible.first }

    init() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let history = root.appendingPathComponent("history.json")
            if FileManager.default.fileExists(atPath: history.path) {
                clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: history))
            }
        } catch { historyWritable = false; message = "历史记录读取失败；本次仍可使用，原文件保留。" }
        // Never import a clipboard left behind during a previous privacy pause on relaunch.
        lastCount = NSPasteboard.general.changeCount
        skipPhoneBaseline = true
        updatePrivacy()
        updateExclusion()
        exclusionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.updateExclusion() }
        refreshConnection()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updatePrivacy()
            self.updateExclusion()
            if !self.paused && !self.privacyPaused && !self.applicationExcluded { self.captureClipboard() }
            else { self.lastCount = NSPasteboard.general.changeCount }
            if self.tick % 75 == 0 { self.trimHistory() }
            self.tick += 1
            if self.tick % 5 == 0 {
                self.refreshConnection()
                if self.online && !self.paused && !self.privacyPaused && !self.applicationExcluded && !self.busy && !self.phoneReading {
                    self.phone("get", automatic: true)
                }
            }
        }
        imageCache.countLimit = 24
    }

    @discardableResult
    func persist(_ items: [Clip]? = nil) -> Bool {
        guard historyWritable else { message = "历史文件不可写，未保存更改"; return false }
        saveVersion += 1
        let version = saveVersion, snapshot = items ?? clips, images = pendingImages
        let liveFiles = Set(snapshot.compactMap(\.file))
        let deletions = pendingDeletes.subtracting(liveFiles)
        let root = self.root
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            do {
                for (file, data) in images where liveFiles.contains(file) {
                    try data.write(to: root.appendingPathComponent(file), options: .atomic)
                }
                try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("history.json"), options: .atomic)
                for file in deletions where FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) {
                    try FileManager.default.removeItem(at: root.appendingPathComponent(file))
                }
                DispatchQueue.main.async {
                    guard let self, self.saveVersion == version else { return }
                    self.pendingImages.removeAll(); self.pendingDeletes.removeAll()
                }
            } catch {
                DispatchQueue.main.async { self?.message = "历史保存或清理失败，当前记录仍在内存中：\(error.localizedDescription)" }
            }
        }
        saveWork = work
        io.asyncAfter(deadline: .now() + 0.3, execute: work)
        return true
    }

    func flushHistory() {
        saveWork?.cancel()
        // A normal quit drains the last snapshot; ordinary interaction never waits for disk IO.
        if historyWritable {
            let snapshot = clips, images = pendingImages, deleted = pendingDeletes
            io.sync {
                do {
                    let live = Set(snapshot.compactMap(\.file))
                    for (file, data) in images where live.contains(file) {
                        try data.write(to: root.appendingPathComponent(file), options: .atomic)
                    }
                    try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("history.json"), options: .atomic)
                    for file in deleted.subtracting(live) where FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) {
                        try FileManager.default.removeItem(at: root.appendingPathComponent(file))
                    }
                } catch { NSLog("Clipboard history could not be flushed: %@", error.localizedDescription) }
            }
        }
    }

    func removalCandidates(using rule: PanelPreferences) -> [Clip] {
        var remaining = clips
        var removed: [Clip] = []
        if rule.days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(rule.days) * 86400)
            removed = remaining.filter { $0.pinnedAt == nil && $0.date < cutoff }
            let ids = Set(removed.map(\.id)); remaining.removeAll { ids.contains($0.id) }
        }
        let candidates = remaining.filter { $0.pinnedAt == nil }.sorted {
            if $0.favorite != $1.favorite { return !$0.favorite }
            return $0.date < $1.date
        }
        var count = remaining.count, bytes = remaining.reduce(0) { $0 + $1.bytes }
        for clip in candidates {
            if count <= rule.count && bytes <= rule.megabytes * 1024 * 1024 { break }
            removed.append(clip); count -= 1; bytes -= clip.bytes
        }
        return removed
    }

    func trimHistory() {
        let removed = removalCandidates(using: preferences)
        if !removed.isEmpty { deleteMany(Set(removed.map(\.id))) }
    }

    func deleteMany(_ ids: Set<String>) {
        guard historyWritable else { message = "历史文件不可写，未执行清理"; return }
        let removed = clips.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        for clip in removed {
            if let file = clip.file { pendingDeletes.insert(file) }
            imageCache.removeObject(forKey: clip.id as NSString)
        }
        clips.removeAll { ids.contains($0.id) }
        if let selected, ids.contains(selected) { self.selected = visible.first?.id }
        persist()
        message = "已移除 \(removed.count) 条本机历史，正在保存"
    }

    func insert(text: String? = nil, image: Data? = nil, mime: String? = nil, source: String, capturedAt: Date = Date(), preparedID: String? = nil) {
        let data = image ?? Data((text ?? "").utf8)
        guard !data.isEmpty else { return }
        guard data.count <= 20 * 1024 * 1024 else { message = "内容超过 20 MB，未加入历史"; return }
        let id = preparedID ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let device = ["鸿蒙手机", "手机截图"].contains(source) ? "手机" : "Mac"
        if let index = clips.firstIndex(where: { $0.id == id }) {
            var item = clips.remove(at: index)
            var devices = item.recordedDevices
            if !devices.contains(device) { devices.append(device) }
            item.devices = devices
            item.date = max(item.date, capturedAt); item.source = source
            clips.insert(item, at: 0)
        } else {
            let file = image == nil ? nil : id + ".image"
            if let file, let image {
                pendingImages[file] = image; pendingDeletes.remove(file)
            }
            clips.insert(Clip(id: id, text: text, file: file, mime: mime, source: source, date: capturedAt, bytes: data.count, devices: [device]), at: 0)
        }
        trimHistory()
        if selected == nil { selected = clips.first?.id }
        persist()
    }

    func captureClipboard(source: String? = nil, force: Bool = false) {
        guard !privacyPaused else { return }
        if !force && (applicationExcluded || exclusions.blocksForeground) { return }
        let pb = NSPasteboard.general
        guard force || pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = pb.types ?? []
        if types.contains(where: { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"].contains($0.rawValue) }) { return }
        let origin = source ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "Mac"
        let token = privacyGeneration, exclusionToken = exclusions.value.generation, date = Date()
        for kind in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType("public.jpeg"), .tiff] {
            if types.contains(kind), let data = pb.data(forType: kind) {
                guard data.count <= 20 * 1024 * 1024 else { message = "图片超过 20 MB，未加入历史"; return }
                processing.async { [weak self] in
                    var converted = data, mime = kind.rawValue
                    if kind == .tiff {
                        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return }
                        converted = png; mime = NSPasteboard.PasteboardType.png.rawValue
                    }
                    guard let thumbnail = Self.thumbnail(converted) else { return }
                    let id = SHA256.hash(data: converted).map { String(format: "%02x", $0) }.joined()
                    let result = converted, resultMime = mime
                    DispatchQueue.main.async {
                        guard let self, !self.privacyPaused, (!self.paused || force), self.privacyGeneration == token,
                              force || (!self.exclusions.blocksForeground && self.exclusions.value.generation == exclusionToken) else { return }
                        self.imageCache.setObject(thumbnail, forKey: id as NSString)
                        self.insert(image: result, mime: resultMime, source: origin, capturedAt: date, preparedID: id)
                        if source == "手机截图" {
                            self.selected = id
                            self.message = "手机截图已加入历史，也可直接粘贴"
                        }
                    }
                }
                return
            }
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            let data = Data(text.utf8)
            guard data.count <= 20 * 1024 * 1024 else { message = "内容超过 20 MB，未加入历史"; return }
            processing.async { [weak self] in
                let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                DispatchQueue.main.async {
                    guard let self, !self.privacyPaused, (!self.paused || force), self.privacyGeneration == token,
                          force || (!self.exclusions.blocksForeground && self.exclusions.value.generation == exclusionToken) else { return }
                    self.insert(text: text, source: origin, capturedAt: date, preparedID: id)
                }
            }
        }
    }

    private static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1000,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    func image(for clip: Clip) -> NSImage? {
        if let cached = imageCache.object(forKey: clip.id as NSString) { return cached }
        guard let file = clip.file, !loadingImages.contains(clip.id) else { return nil }
        loadingImages.insert(clip.id)
        let pending = pendingImages[file], url = root.appendingPathComponent(file)
        processing.async { [weak self] in
            let image = (pending ?? (try? Data(contentsOf: url))).flatMap { Self.thumbnail($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                // Keep failed loads marked until the record is replaced; do not spin on a missing file.
                if let image { self.imageCache.setObject(image, forKey: clip.id as NSString); self.loadingImages.remove(clip.id); self.imageRevision += 1 }
            }
        }
        return nil
    }

    func imageData(for clip: Clip) -> Data? { clip.file.flatMap { pendingImages[$0] } }

    @discardableResult
    func copyText(_ text: String, paste: Bool = false) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else { message = "复制失败，请重试"; return false }
        lastCount = board.changeCount
        message = "已复制文字，原记录保持不变"
        if paste {
            let expected = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard board.changeCount == expected else { self?.message = "剪贴板已变化，已取消粘贴"; return }
                self?.paste?()
            }
        }
        return true
    }

    func updateExclusion() {
        let blocked = exclusions.blocksForeground, stamp = exclusions.value.generation
        if blocked != applicationExcluded || stamp != exclusionStamp {
            applicationExcluded = blocked; exclusionStamp = stamp; historyPauseChanged()
            if blocked { message = "前台应用已排除，自动记录与同步暂停" }
            else { message = "已恢复自动记录，已跳过排除期间的内容" }
        }
    }

    func copySelected(close: Bool = false, plainText: Bool = false) {
        guard let clip = current else { return }
        if plainText && clip.isImage { message = "图片不能作为纯文本粘贴"; return }
        let pb = NSPasteboard.general
        if let file = clip.file, let mime = clip.mime {
            guard let data = pendingImages[file] ?? (try? Data(contentsOf: root.appendingPathComponent(file))) else { message = "图片文件不可用"; return }
            pb.clearContents()
            guard pb.setData(data, forType: .init(mime)) else { message = "复制图片失败"; return }
        } else if let text = clip.text {
            pb.clearContents()
            guard pb.setString(text, forType: .string) else { message = "复制文字失败"; return }
        }
        lastCount = pb.changeCount
        message = "已复制，在目标应用按 ⌘V 粘贴"
        if close { paste?() }
    }

    func favoriteSelected() {
        guard let id = current?.id, let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].favorite.toggle(); persist()
    }

    func togglePin(_ id: String) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        var updated = clips
        updated[index].pinnedAt = updated[index].pinnedAt == nil ? Date() : nil
        guard persist(updated) else { return }
        clips = updated; selected = id
        message = updated[index].pinnedAt == nil ? "已取消置顶" : "已置顶，重新打开后仍保留"
    }

    func delete(_ id: String) {
        if let text = clips.first(where: { $0.id == id })?.text { lastPhoneText = text }
        deleteMany([id])
    }

    func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex(where: { $0.id == current?.id }) ?? 0
        selected = list[max(0, min(list.count - 1, index + delta))].id
    }

    func selectNumber(_ number: Int) {
        guard visible.indices.contains(number) else { return }
        selected = visible[number].id; copySelected(close: true)
    }

    func historyPauseChanged() {
        privacyGeneration = UUID(); lastCount = NSPasteboard.general.changeCount
        skipPhoneBaseline = true
    }

    func setPrivacy(minutes: Int?) {
        writePrivacy(PrivacyState(paused: true, until: minutes.map { Date().timeIntervalSince1970 + Double($0) * 60 }))
    }

    func resumePrivacy() { writePrivacy(PrivacyState(paused: false, until: nil)) }

    private func writePrivacy(_ value: PrivacyState) {
        do {
            try FileManager.default.createDirectory(at: PrivacyState.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: PrivacyState.url, options: .atomic)
            updatePrivacy()
            message = value.active ? "隐私暂停已开启，正在结束在途采集" : "隐私暂停已恢复，已跳过暂停期间的内容"
            refreshConnection()
        } catch { message = "隐私状态保存失败，未能应用：\(error.localizedDescription)" }
    }

    func updatePrivacy() {
        var active = false, label = ""
        do {
            if FileManager.default.fileExists(atPath: PrivacyState.url.path) {
                let value = try JSONDecoder().decode(PrivacyState.self, from: Data(contentsOf: PrivacyState.url))
                active = value.active
                if let until = value.until, active {
                    label = "暂停至 " + Date(timeIntervalSince1970: until).formatted(date: .omitted, time: .shortened)
                } else if active { label = "已暂停，等待手动恢复" }
            }
        } catch { active = true; label = "隐私配置读取失败，已暂停；请手动恢复后重试" }
        if privacyPaused != active {
            privacyPaused = active; historyPauseChanged()
            refreshConnection()
        }
        if privacyLabel != label { privacyLabel = label }
    }

    func refreshConnection() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HarmonyClipboard")
        if privacyPaused { online = false; connection = "隐私暂停中"; connectionDetail = privacyLabel; return }
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("config.json").path) else {
            online = false; connection = "尚未配置手机"; connectionDetail = "在设置中填写手机 IP 与无线调试端口"; return
        }
        let url = base.appendingPathComponent("status.json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            online = false; connection = "同步服务未运行"; connectionDetail = "可在设置中启动同步"; return
        }
        lastSync = (value["last_sync"] as? String).map { $0 + " · " + (value["last_direction"] as? String ?? "") } ?? "尚无同步记录"
        let state = value["state"] as? String
        if state == "stopped" { online = false; connection = "同步已停止"; connectionDetail = "可手动恢复同步"; return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let updated = attributes[.modificationDate] as? Date, Date().timeIntervalSince(updated) < 60 else {
            online = false; connection = "服务状态已过期"; connectionDetail = "后台服务可能退出，尝试立即重连"; return
        }
        online = value["connected"] as? Bool == true
        if state == "application_excluded" { connection = "应用排除中"; connectionDetail = "前台应用的自动历史与双向同步已暂停"; return }
        connection = online ? (state == "phone_read_unavailable" ? "手机已连接 · 读取需解锁" : "手机已连接") : "手机连接失败 · 重试中"
        connectionDetail = online ? (state == "phone_read_unavailable" ? "请解锁手机后再取文字" : "文字同步可用") : "检查手机无线调试、授权和 IP／端口；也可立即重连"
    }

    func phone(_ action: String, automatic: Bool = false, inputText: String? = nil) {
        guard !busy else { return }
        if automatic && exclusions.blocksForeground { return }
        if privacyPaused && ["get", "send", "capture", "reconnect"].contains(action) { message = "请先恢复隐私暂停"; return }
        let requestGeneration = privacyGeneration
        let text = action == "send" ? current?.text : inputText
        if action == "send" && text == nil { message = "这一版支持向手机发送文字"; return }
        if let text, text.utf8.count > 16 * 1024 { message = "手机文字同步最多支持 16 KB"; return }
        guard let script = Bundle.main.path(forResource: "phone", ofType: "py") else { message = "手机操作组件缺失"; return }
        if automatic { phoneReading = true }
        else {
            busy = true
            message = action == "capture" ? "正在获取手机截图…" : "正在同步…"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-B", script, action]
            let output = Pipe(); let input = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.standardInput = input
            do {
                try process.run()
                if let text { try input.fileHandleForWriting.write(contentsOf: Data(text.utf8)) }
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                DispatchQueue.main.async {
                    guard let self else { return }
                    if automatic { self.phoneReading = false } else { self.busy = false }
                    guard reply?["ok"] as? Bool == true else {
                        if !automatic { self.message = reply?["error"] as? String ?? "同步失败，请检查手机连接" }
                        return
                    }
                    if let value = reply?["panel_autostart"] as? Bool { self.panelAutostart = value }
                    if let value = reply?["sync_autostart"] as? Bool { self.syncAutostart = value }
                    if ["get", "capture"].contains(action) && (self.privacyPaused || self.privacyGeneration != requestGeneration) { return }
                    if let value = reply?["text"] as? String {
                        if automatic && self.skipPhoneBaseline { self.skipPhoneBaseline = false; self.lastPhoneText = value; return }
                        if automatic && (self.paused || self.privacyPaused || self.exclusions.blocksForeground || self.lastPhoneText == value) { return }
                        self.lastPhoneText = value
                        self.insert(text: value, source: "鸿蒙手机")
                        if !automatic {
                            self.filter = "全部"; self.deviceFilter = "手机"; self.query = ""; self.selected = self.clips.first?.id
                            self.message = "手机文字已加入历史，选中后可复制"
                        }
                    } else if action == "capture" {
                        self.captureClipboard(source: "手机截图", force: true)
                        self.filter = "全部"; self.deviceFilter = "手机"; self.query = ""; self.selected = self.clips.first?.id
                        self.message = "手机截图已取回，正在加入历史…"
                    } else { self.message = reply?["message"] as? String ?? "同步完成" }
                    self.refreshConnection()
                }
            } catch {
                if process.isRunning { process.terminate() }
                DispatchQueue.main.async {
                    if automatic { self?.phoneReading = false }
                    else { self?.busy = false; self?.message = "同步操作失败，请检查手机连接" }
                }
            }
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = ClipboardStore()
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var keyMonitor: Any?
    var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var pasteGeneration = UUID()
    var configuringPhone = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "接力剪贴板")
        appMenu.addItem(withTitle: "退出接力剪贴板", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "接力剪贴板"
        panel.isFloatingPanel = true; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PanelView(store: store))
        store.dismiss = { [weak self] in self?.hide(restoreFocus: true) }
        store.paste = { [weak self] in self?.pasteIntoPreviousApp() }
        store.configurePhone = { [weak self] in self?.store.settingsPresented = true }
        store.changeHotkey = { [weak self] preference in self?.registerShortcut(preference) ?? false }
        NotificationCenter.default.addObserver(self, selector: #selector(showPhoneSettings), name: .init("EditPhoneEndpoint"), object: nil)
        // Menu-bar clicks can activate this app before show() runs; remember the last external app.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.previousApp = app
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "接力剪贴板")
        statusItem.button?.toolTip = "接力剪贴板 · Control + X"
        statusItem.button?.target = self; statusItem.button?.action = #selector(toggle)
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            delegate.toggle(); return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        store.hotkeyAvailable = registerShortcut(store.preferences)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow, self.panel.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            if event.keyCode == 53 { self.hide(restoreFocus: true); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" {
                NotificationCenter.default.post(name: .init("FocusClipboardSearch"), object: nil); return nil
            }
            if event.modifierFlags.contains(.command), let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number) {
                self.store.selectNumber(number - 1); return nil
            }
            if event.keyCode == 125 { self.store.move(1); return nil }
            if event.keyCode == 126 { self.store.move(-1); return nil }
            if event.keyCode == 36 {
                if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                self.store.copySelected(close: true, plainText: event.modifierFlags.contains(.shift)); return nil
            }
            return event
        }
        // Keep login launches quiet; the hotkey and menu-bar button reveal the panel.
    }

    func registerShortcut(_ preference: PanelPreferences) -> Bool {
        if hotKey != nil && preference.letter == store.preferences.letter && preference.modifier == store.preferences.modifier { return true }
        var candidate: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x48434C50, id: 1)
        guard RegisterEventHotKey(preference.keyCode, preference.modifierMask, id, GetApplicationEventTarget(), 0, &candidate) == noErr else { return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        statusItem.button?.toolTip = "接力剪贴板 · " + preference.shortcutLabel
        return true
    }
    @objc func toggle() {
        if panel.attachedSheet != nil { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); return }
        panel.isVisible ? hide(restoreFocus: true) : show()
    }
    func show() {
        pasteGeneration = UUID()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        store.refreshConnection()
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.midY - panel.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    private func pasteIntoPreviousApp() {
        guard let target = previousApp, !target.isTerminated else {
            store.message = "已复制；请先聚焦目标输入框，再用 Control+X 呼出面板"; return
        }
        guard AXIsProcessTrusted() else {
            let alert = NSAlert()
            alert.messageText = "直接粘贴需要辅助功能权限"
            alert.informativeText = "授权后，按回车或双击记录即可向原应用发送一次 ⌘V。内容已复制；未授权时仍可手动粘贴。"
            alert.addButton(withTitle: "打开辅助功能设置"); alert.addButton(withTitle: "仅复制并收起")
            if alert.runModal() == .alertFirstButtonReturn {
                hide(restoreFocus: false)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            } else { hide(restoreFocus: true) }
            return
        }
        let token = UUID(); pasteGeneration = token
        let count = NSPasteboard.general.changeCount
        hide(restoreFocus: false)
        guard target.activate(options: []) else { store.message = "无法切回目标应用，内容已复制"; return }
        finishPaste(target: target, count: count, token: token, attempts: 20)
    }
    private func finishPaste(target: NSRunningApplication, count: Int, token: UUID, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.pasteGeneration == token else { return }
            guard !target.isTerminated, NSPasteboard.general.changeCount == count else {
                self.store.message = "目标应用或剪贴板已变化，已取消自动粘贴"; return
            }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front == target.processIdentifier {
                guard let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                    self.store.message = "无法发送粘贴操作，内容已复制"; return
                }
                down.flags = .maskCommand; up.flags = .maskCommand
                down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
                self.store.message = "已向 \(target.localizedName ?? "原应用") 发送粘贴操作"
            } else if front == ProcessInfo.processInfo.processIdentifier && attempts > 1 {
                self.finishPaste(target: target, count: count, token: token, attempts: attempts - 1)
            } else { self.store.message = "前台应用已变化，未自动粘贴；内容已复制" }
        }
    }
    func hide(restoreFocus: Bool) {
        panel.orderOut(nil)
        if restoreFocus, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
    }
    func windowDidResignKey(_ notification: Notification) { if !store.pinned && !configuringPhone && panel.attachedSheet == nil { hide(restoreFocus: false) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { show() }; return true }
    func applicationWillTerminate(_ notification: Notification) {
        pasteGeneration = UUID()
        store.flushHistory()
        NotificationCenter.default.removeObserver(self)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

umask(0o077)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Installer upgrades send SIGTERM; flush history even if an open sheet prevents AppKit termination.
signal(SIGTERM, SIG_IGN)
let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSignal.setEventHandler { delegate.store.flushHistory(); exit(EXIT_SUCCESS) }
terminationSignal.resume()
app.run()
