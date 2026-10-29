import AppKit
import SwiftUI
import Carbon
import CryptoKit
import ApplicationServices

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
    var title: String { text?.replacingOccurrences(of: "\n", with: " ") ?? "图片 · \(source)" }
}

final class ClipboardStore: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var selected: String?
    @Published var query = ""
    @Published var filter = "全部"
    @Published var deviceFilter = "全部设备"
    @Published var pinned = false
    @Published var paused = false
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
            && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query))
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
        captureClipboard(source: "Mac 剪贴板")
        refreshConnection()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.paused { self.captureClipboard() }
            self.tick += 1
            if self.tick % 5 == 0 {
                self.refreshConnection()
                if self.online && !self.paused && !self.busy && !self.phoneReading {
                    self.phone("get", automatic: true)
                }
            }
        }
        imageCache.countLimit = 24
    }

    @discardableResult
    func persist(_ items: [Clip]? = nil) -> Bool {
        guard historyWritable else { message = "历史文件不可写，未保存更改"; return false }
        do {
            try JSONEncoder().encode(items ?? clips).write(to: root.appendingPathComponent("history.json"), options: .atomic)
            return true
        } catch { message = "历史记录保存失败，当前内容仍在内存中。"; return false }
    }

    func insert(text: String? = nil, image: Data? = nil, mime: String? = nil, source: String) {
        let data = image ?? Data((text ?? "").utf8)
        guard !data.isEmpty else { return }
        guard data.count <= 20 * 1024 * 1024 else { message = "内容超过 20 MB，未加入历史"; return }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let device = ["鸿蒙手机", "手机截图"].contains(source) ? "手机" : "Mac"
        if let index = clips.firstIndex(where: { $0.id == id }) {
            var item = clips.remove(at: index)
            var devices = item.recordedDevices
            if !devices.contains(device) { devices.append(device) }
            item.devices = devices
            item.date = Date(); item.source = source
            clips.insert(item, at: 0)
        } else {
            let file = image == nil ? nil : id + ".image"
            if let file, let image {
                do { try image.write(to: root.appendingPathComponent(file), options: .atomic) }
                catch { message = "图片保存失败，未加入历史"; return }
            }
            clips.insert(Clip(id: id, text: text, file: file, mime: mime, source: source, date: Date(), bytes: data.count, devices: [device]), at: 0)
        }
        // Pinned records survive automatic cleanup; ordinary records go before favorites.
        while clips.count > 100 || clips.reduce(0, { $0 + $1.bytes }) > 100 * 1024 * 1024 {
            guard let index = clips.lastIndex(where: { $0.pinnedAt == nil && !$0.favorite }) ?? clips.lastIndex(where: { $0.pinnedAt == nil }) else { break }
            let old = clips.remove(at: index)
            if old.id == id { message = "历史空间已满，请取消部分置顶或删除记录" }
            if let file = old.file { try? FileManager.default.removeItem(at: root.appendingPathComponent(file)) }
            imageCache.removeObject(forKey: old.id as NSString)
        }
        if selected == nil { selected = clips.first?.id }
        persist()
    }

    func captureClipboard(source: String? = nil, force: Bool = false) {
        let pb = NSPasteboard.general
        guard force || pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = pb.types ?? []
        if types.contains(where: { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"].contains($0.rawValue) }) { return }
        let origin = source ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "Mac"
        for kind in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType("public.jpeg")] {
            if types.contains(kind), let data = pb.data(forType: kind), NSImage(data: data) != nil {
                insert(image: data, mime: kind.rawValue, source: origin); return
            }
        }
        if types.contains(.tiff), let data = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            insert(image: png, mime: NSPasteboard.PasteboardType.png.rawValue, source: origin); return
        }
        if let text = pb.string(forType: .string), !text.isEmpty { insert(text: text, source: origin) }
    }

    func image(for clip: Clip) -> NSImage? {
        if let cached = imageCache.object(forKey: clip.id as NSString) { return cached }
        guard let file = clip.file, let image = NSImage(contentsOf: root.appendingPathComponent(file)) else { return nil }
        imageCache.setObject(image, forKey: clip.id as NSString)
        return image
    }

    func copySelected(close: Bool = false) {
        guard let clip = current else { return }
        let pb = NSPasteboard.general
        if let file = clip.file, let mime = clip.mime {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { message = "图片文件不可用"; return }
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
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        let position = visible.firstIndex(where: { $0.id == id }) ?? 0
        let updated = clips.filter { $0.id != id }
        guard persist(updated) else { return }
        clips = updated; imageCache.removeObject(forKey: id as NSString)
        if selected == id || selected == nil { selected = visible.isEmpty ? nil : visible[min(position, visible.count - 1)].id }
        // Do not immediately re-import the same phone value during the next polling cycle.
        if let text = clip.text { lastPhoneText = text }
        message = "已删除本机记录；设备当前剪贴板未清空"
        if let file = clip.file {
            do { try FileManager.default.removeItem(at: root.appendingPathComponent(file)) }
            catch { message = "记录已删除，但图片文件清理失败：\(error.localizedDescription)" }
        }
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

    func refreshConnection() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HarmonyClipboard/status.json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let updated = attributes[.modificationDate] as? Date, Date().timeIntervalSince(updated) < 60 else {
            online = false; connection = "同步服务未运行"; return
        }
        online = value["connected"] as? Bool == true
        let state = value["state"] as? String
        connection = online ? (state == "phone_read_unavailable" ? "手机已连接 · 读取需解锁" : "手机已连接")
            : (state == "stopped" ? "同步已停止" : "手机正在重连")
    }

    func phone(_ action: String, automatic: Bool = false, inputText: String? = nil) {
        guard !busy else { return }
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
                    if let value = reply?["text"] as? String {
                        if automatic && (self.paused || self.lastPhoneText == value) { return }
                        self.lastPhoneText = value
                        self.insert(text: value, source: "鸿蒙手机")
                        if !automatic {
                            self.filter = "全部"; self.deviceFilter = "手机"; self.query = ""; self.selected = self.clips.first?.id
                            self.message = "手机文字已加入历史，选中后可复制"
                        }
                    } else if action == "capture" {
                        self.captureClipboard(source: "手机截图", force: true)
                        self.filter = "全部"; self.deviceFilter = "手机"; self.query = ""; self.selected = self.clips.first?.id
                        self.message = "手机截图已加入历史，也可直接粘贴"
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

struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow
        view.blendingMode = .behindWindow; view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PanelView: View {
    @ObservedObject var store: ClipboardStore
    @FocusState var searchFocused: Bool
    @State private var deletionID: String?
    @State private var confirmsDeletion = false
    private let accent = Color(red: 0.60, green: 0.68, blue: 1)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "square.on.square").font(.system(size: 23, weight: .medium)).foregroundStyle(accent)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索剪贴板", text: $store.query).textFieldStyle(.plain).focused($searchFocused)
                    Text("⌘F").font(.system(size: 12)).foregroundStyle(.tertiary)
                }.padding(11).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 8)
                Button { store.phone("get") } label: {
                    Label("取手机文字", systemImage: "arrow.down.doc").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                }.disabled(store.busy).help("读取手机当前文字并加入历史")
                Button { store.phone("capture") } label: {
                    Label("手机截图", systemImage: "camera").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                }.disabled(store.busy).help("截取手机当前屏幕并加入历史")
                Circle().fill(store.online ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(store.connection).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { store.pinned.toggle() } label: { Image(systemName: store.pinned ? "pin.fill" : "pin") }
                    .help(store.pinned ? "取消固定面板" : "固定面板").foregroundStyle(store.pinned ? accent : .secondary)
                    .accessibilityLabel("固定面板")
                Menu {
                    Toggle("暂停记录", isOn: $store.paused)
                    Button("恢复手机同步") { store.phone("start") }.disabled(store.busy)
                    Button("暂停手机同步") { store.phone("stop") }.disabled(store.busy)
                    Button("打开历史存储目录") { NSWorkspace.shared.open(store.root) }
                    Divider()
                    Text("本机历史最多 100 条 / 100 MB")
                    Text("单条最多 20 MB · 文字发送最多 16 KB")
                    Divider()
                    Button("退出接力剪贴板") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多")
                Button { store.configurePhone?() } label: { Image(systemName: "gearshape") }
                    .help("手机连接设置 · IP 与端口").accessibilityLabel("手机连接设置").disabled(store.busy)
                Button { store.dismiss?() } label: { Image(systemName: "xmark") }.help("收起 · Esc").accessibilityLabel("收起面板")
            }.buttonStyle(.plain).padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            HStack(spacing: 8) {
                ForEach(["全部", "文字", "图片", "收藏"], id: \.self) { category in
                    Button { store.filter = category; store.selected = store.visible.first?.id } label: {
                        HStack(spacing: 6) {
                            if category != "全部" { Circle().fill(category == "文字" ? Color.purple : category == "图片" ? Color.green : accent).frame(width: 6, height: 6) }
                            Text(category).font(.system(size: 13, weight: .medium))
                        }.padding(.horizontal, 14).padding(.vertical, 8)
                            .background(store.filter == category ? .white.opacity(0.12) : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text(store.paused ? "记录已暂停" : "\(store.clips.count) 条记录").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 22).padding(.bottom, 16)
            HStack(spacing: 7) {
                ForEach(["全部设备", "Mac", "手机"], id: \.self) { device in
                    Button {
                        store.deviceFilter = device; store.selected = store.visible.first?.id
                    } label: {
                        Label(device, systemImage: device == "Mac" ? "desktopcomputer" : device == "手机" ? "iphone" : "square.stack.3d.up")
                            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(store.deviceFilter == device ? accent.opacity(0.18) : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("记录开启后的内容 · 手机文字约 4 秒采集一次").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 22).padding(.bottom, 12)
            HStack(spacing: 18) {
                history.frame(width: 324)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 18)
            HStack(spacing: 10) {
                if store.busy { ProgressView().controlSize(.small).scaleEffect(0.75) }
                Text(store.hotkeyAvailable ? store.message : "Control + X 已被占用，请先释放快捷键后重新启动应用")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Text("↑↓ 选择   ↩ 粘贴   ⌃X 呼出").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.frame(height: 44).padding(.horizontal, 24)
        }
        .background { ZStack { Glass(); Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.70) } }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.16), lineWidth: 1))
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .init("FocusClipboardSearch"))) { _ in searchFocused = true }
        .alert("删除这条历史记录？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) { deletionID = nil }
            Button("删除", role: .destructive) { if let deletionID { store.delete(deletionID) }; deletionID = nil }
        } message: {
            Text("只删除本机历史记录及其图片文件，不会清空 Mac 或手机当前剪贴板。")
        }
    }

    var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if store.visible.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 30)).foregroundStyle(.tertiary)
                            Text(store.query.isEmpty ? "复制一段文字或一张图片\n它就会出现在这里" : "没有匹配的记录")
                                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.top, 70)
                    }
                    ForEach(Array(store.visible.enumerated()), id: \.element.id) { index, clip in
                        HStack(spacing: 12) {
                            Text(index < 9 ? "⌘\(index + 1)" : " ").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 24)
                            if clip.isImage {
                                if let image = store.image(for: clip) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 38, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
                                } else { Image(systemName: "photo").frame(width: 38) }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(clip.title).font(.system(size: 13, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 4) {
                                    Text(clip.deviceLabel).lineLimit(1)
                                    Text("·")
                                    Text(clip.date, style: .relative).lineLimit(1)
                                    if clip.favorite { Image(systemName: "star.fill").foregroundStyle(accent) }
                                    if clip.pinnedAt != nil { Image(systemName: "pin.fill").foregroundStyle(accent).accessibilityLabel("已置顶") }
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if !clip.isImage {
                                Button {
                                    store.selected = clip.id
                                    store.phone("send")
                                } label: {
                                    Image(systemName: "paperplane").font(.system(size: 13))
                                        .foregroundStyle(accent).frame(width: 28, height: 32)
                                }.buttonStyle(.plain).disabled(store.busy)
                                    .help("发送这条文字到手机剪贴板")
                                    .accessibilityLabel("发送这条文字到手机")
                            }
                        }.padding(12).frame(minHeight: 70)
                            .background(store.current?.id == clip.id ? accent.opacity(0.19) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { store.selected = clip.id; store.copySelected(close: true) }
                            // Select immediately instead of waiting for the double-click interval.
                            .simultaneousGesture(TapGesture().onEnded { store.selected = clip.id })
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(clip.title)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { store.selected = clip.id }
                            .contextMenu {
                                Button(clip.pinnedAt == nil ? "置顶" : "取消置顶") { store.togglePin(clip.id) }
                                Button("复制") { store.selected = clip.id; store.copySelected() }
                                Button("删除记录", role: .destructive) { deletionID = clip.id; confirmsDeletion = true }
                            }
                            .id(clip.id)
                    }
                }
            }.onChange(of: store.selected) { _, value in if let value { proxy.scrollTo(value) } }
        }
    }

    var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.current?.isImage == true ? "图片预览" : "内容预览").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { if let id = store.current?.id { store.togglePin(id) } } label: { Image(systemName: store.current?.pinnedAt == nil ? "pin" : "pin.fill") }
                    .help("置顶 / 取消置顶记录").accessibilityLabel("置顶所选记录").disabled(store.current == nil)
                Button { store.favoriteSelected() } label: { Image(systemName: store.current?.favorite == true ? "star.fill" : "star") }
                    .help("收藏 / 取消收藏").accessibilityLabel("收藏所选内容").disabled(store.current == nil)
                Button { store.copySelected() } label: { Label("复制", systemImage: "doc.on.doc") }
                    .help("复制到 Mac 剪贴板").disabled(store.current == nil)
                Button { store.copySelected(close: true) } label: { Label("粘贴", systemImage: "arrow.up.forward.app") }
                    .help("粘贴到呼出面板前的应用 · 回车").disabled(store.current == nil)
                Button { deletionID = store.current?.id; confirmsDeletion = true } label: { Image(systemName: "trash") }
                    .help("删除所选记录").accessibilityLabel("删除所选记录").disabled(store.current == nil)
            }.buttonStyle(.plain).foregroundStyle(accent).padding(18)
            if let clip = store.current {
                if clip.isImage, let image = store.image(for: clip) {
                    Image(nsImage: image).resizable().scaledToFit().padding(.horizontal, 22).padding(.bottom, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { Text(clip.text ?? "图片文件不可用").font(.system(size: 16)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 20) }.frame(maxHeight: .infinity)
                }
                HStack(spacing: 8) {
                    Image(systemName: clip.isImage ? "photo" : "text.alignleft")
                    Text(clip.deviceLabel + " · " + clip.source)
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file))
                    Spacer()
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(accent.opacity(0.6))
                    Text("选一条内容，接着用").font(.system(size: 18, weight: .medium))
                    Text("文字可双向同步，手机画面可一键取回").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.065), lineWidth: 1))
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
        store.configurePhone = { [weak self] in self?.showPhoneSettings() }
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
        let id = EventHotKeyID(signature: 0x48434C50, id: 1)
        store.hotkeyAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(controlKey), id, GetApplicationEventTarget(), 0, &hotKey) == noErr
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
                self.store.copySelected(close: true); return nil
            }
            return event
        }
        // Keep login launches quiet; the hotkey and menu-bar button reveal the panel.
    }

    @objc func toggle() { panel.isVisible ? hide(restoreFocus: true) : show() }
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
    func windowDidResignKey(_ notification: Notification) { if !store.pinned && !configuringPhone { hide(restoreFocus: false) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { show() }; return true }
    func applicationWillTerminate(_ notification: Notification) {
        pasteGeneration = UUID()
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
app.run()
