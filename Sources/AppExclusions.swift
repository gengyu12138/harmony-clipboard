import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExcludedApplication: Codable, Identifiable {
    var id: String
    var name: String
}

struct AppExclusions: Codable {
    var applications: [ExcludedApplication] = []
    var generation = UUID().uuidString
    static let url = PrivacyState.url.deletingLastPathComponent().appendingPathComponent("exclusions.json")
}

final class ExclusionStore: ObservableObject {
    @Published private(set) var value = AppExclusions()
    @Published private(set) var error = ""
    private var unreadable = false
    init() { reload() }
    func reload() {
        do {
            if FileManager.default.fileExists(atPath: AppExclusions.url.path) {
                let loaded = try JSONDecoder().decode(AppExclusions.self, from: Data(contentsOf: AppExclusions.url))
                guard !loaded.applications.contains(where: { $0.id.isEmpty }) else { throw CocoaError(.fileReadCorruptFile) }
                value = loaded
            } else {
                value = AppExclusions()
            }
            error = ""; unreadable = false
        } catch { unreadable = true; self.error = "应用排除配置不可读，已暂停自动记录与同步；请修复配置文件后重试。" }
    }
    var blocksForeground: Bool {
        unreadable || value.applications.contains { $0.id == NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }
    func save(_ applications: [ExcludedApplication]) {
        guard error.isEmpty else { return }
        do {
            let next = AppExclusions(applications: applications)
            try FileManager.default.createDirectory(at: AppExclusions.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: AppExclusions.url, options: .atomic)
            value = next
        } catch { self.error = "保存排除配置失败，仍使用原规则；请重试读取。" }
    }
    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.prompt = "排除此应用"; panel.message = "此应用在前台时暂停自动历史与双向同步。"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            guard id != Bundle.main.bundleIdentifier else { self.error = "不能排除接力剪贴板自身，请点击重试读取。"; return }
            guard !self.value.applications.contains(where: { $0.id == id }) else { return }
            self.save(self.value.applications + [ExcludedApplication(id: id, name: FileManager.default.displayName(atPath: url.path))])
        }
    }
}

struct ApplicationExclusionSettings: View {
    @ObservedObject var exclusions: ExclusionStore
    var body: some View {
        SettingSection(title: "按应用排除") {
            Text("选中应用在前台时，暂停自动记录和双向文字同步；离开时跳过当前剪贴板，不补录、不补发。手动取手机文字和发送仍可使用。")
                .font(.system(size: 12)).foregroundStyle(RelayTheme.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(exclusions.value.applications) { application in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(application.name)
                        Text(application.id).font(.system(size: 10)).foregroundStyle(RelayTheme.muted)
                    }
                    Spacer()
                    RelayIconButton(title: "移除排除：" + application.name, symbol: "minus.circle") {
                        exclusions.save(exclusions.value.applications.filter { $0.id != application.id })
                    }
                }
            }
            HStack {
                Button("添加应用…") { exclusions.chooseApplication() }.buttonStyle(RelayButtonStyle()).disabled(!exclusions.error.isEmpty)
                if !exclusions.error.isEmpty {
                    Button("重试读取") { exclusions.reload() }.buttonStyle(RelayButtonStyle())
                }
            }
            if !exclusions.error.isEmpty { Text(exclusions.error).font(.system(size: 12)).foregroundStyle(RelayTheme.warning) }
            Text("根据前台应用判断，不能精确追溯剪贴板来源。快速切换应用、后台应用复制及手机来源应用无法保证排除；敏感操作请使用“隐私暂停”。")
                .font(.system(size: 11)).foregroundStyle(RelayTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
