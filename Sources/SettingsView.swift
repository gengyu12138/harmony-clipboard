import SwiftUI

private enum SettingsPage: String, CaseIterable {
    case connection = "手机连接", general = "通用", history = "历史记录", privacy = "隐私"
    var symbol: String {
        switch self {
        case .connection: return "laptopcomputer.and.iphone"
        case .general: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "hand.raised"
        }
    }
    var subtitle: String {
        switch self {
        case .connection: return "同一局域网，让文字在设备之间接力。"
        case .general: return "按你的习惯呼出，登录后安静待命。"
        case .history: return "为有用的内容留出空间。"
        case .privacy: return "需要时暂停，记录与同步一起停下。"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var page = SettingsPage.connection
    @State private var draft = PanelPreferences()
    @State private var confirmRules = false
    @State private var confirmCleanup = false
    @State private var cleanupIDs: Set<String> = []
    @State private var affectedCount = 0
    @State private var affectedBytes = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(RelayTheme.line).frame(width: 0.5)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.rawValue).font(.system(size: 22, weight: .semibold))
                        Text(page.subtitle).font(.system(size: 12)).foregroundStyle(RelayTheme.secondary)
                    }
                    Spacer()
                    RelayIconButton(title: "关闭设置", symbol: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
                }.padding(24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch page {
                        case .connection: connection
                        case .general: general
                        case .history: history
                        case .privacy: privacy
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle().fill(RelayTheme.line).frame(height: 0.5)
                HStack(spacing: 12) {
                    Text(draft != store.preferences ? "快捷键或保留规则有未保存的修改" : store.message)
                        .font(.system(size: 11)).foregroundStyle(RelayTheme.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    if draft != store.preferences {
                        Button("保存修改") { saveRules() }.buttonStyle(RelayButtonStyle(prominent: true))
                    } else {
                        Button("完成") { dismiss() }.buttonStyle(RelayButtonStyle())
                    }
                }.padding(.horizontal, 24).frame(height: 64)
            }
        }.frame(width: 820, height: 580).modifier(GlassShell())
            .font(.system(size: 13))
            .onAppear { draft = store.preferences; store.phone("services") }
            .alert("应用新的清理规则？", isPresented: $confirmRules) {
                Button("取消", role: .cancel) {}
                Button("保存并按规则清理", role: .destructive) { store.applyPreferences(draft) }
            } message: { Text("当前约 \(affectedCount) 条记录（\(ByteCountFormatter.string(fromByteCount: Int64(affectedBytes), countStyle: .file))）将被移除，包括符合规则的收藏；之后也会自动清理，无回收站。置顶记录保留。") }
            .alert("清理非置顶历史？", isPresented: $confirmCleanup) {
                Button("取消", role: .cancel) {}
                Button("清理这 \(affectedCount) 条", role: .destructive) { store.deleteMany(cleanupIDs) }
            } message: { Text("将删除 \(affectedCount) 条记录及图片，共 \(ByteCountFormatter.string(fromByteCount: Int64(affectedBytes), countStyle: .file))，包括未置顶的收藏。没有回收站；设备当前剪贴板不会清空。") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(RelayTheme.accent)
                Text("接力剪贴板").font(.system(size: 14, weight: .semibold))
            }.padding(.top, 27).padding(.bottom, 25).padding(.horizontal, 10)
            Text("设置").font(.system(size: 11, weight: .medium)).foregroundStyle(RelayTheme.muted).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(SettingsPage.allCases, id: \.self) { item in
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.rawValue)
                        Spacer()
                    }.frame(height: 8)
                }.buttonStyle(RelayButtonStyle(selected: page == item, quiet: true))
                    .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer()
            HStack(spacing: 6) { Image(systemName: "lock.shield"); Text("历史仅保存在本机") }
                .font(.system(size: 10)).foregroundStyle(RelayTheme.muted).padding(.horizontal, 8).padding(.bottom, 22)
        }.padding(.horizontal, 14).frame(width: 176).background(.black.opacity(0.10))
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingSection(title: "连接状态") {
                HStack(spacing: 14) {
                    Image(systemName: store.privacyPaused ? "pause.circle" : store.online ? "checkmark.circle" : "wifi.exclamationmark")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(store.online ? RelayTheme.accent : RelayTheme.warning)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.connection).font(.system(size: 16, weight: .semibold))
                        hint(store.connectionDetail)
                    }
                    Spacer()
                    Button("立即重连") { store.phone("reconnect") }.buttonStyle(RelayButtonStyle()).disabled(store.busy || store.privacyPaused)
                }
                Divider().overlay(RelayTheme.line)
                VStack(alignment: .leading, spacing: 5) {
                    Text("最后成功同步").font(.system(size: 11)).foregroundStyle(RelayTheme.muted)
                    Text(store.lastSync).font(.system(size: 12)).textSelection(.enabled)
                }
            }
            SettingSection(title: "设备与同步") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("手机无线调试地址"); hint("地址变化后，在这里更新 IP 和端口。") }
                    Spacer()
                    Button("修改 IP / 端口") { NotificationCenter.default.post(name: .init("EditPhoneEndpoint"), object: nil) }
                        .buttonStyle(RelayButtonStyle()).disabled(store.busy)
                }
                Divider().overlay(RelayTheme.line)
                HStack(spacing: 8) {
                    Button("启动同步") { store.phone("start") }.buttonStyle(RelayButtonStyle()).disabled(store.busy)
                    Button("停止同步") { store.phone("stop") }.buttonStyle(RelayButtonStyle()).disabled(store.busy)
                    Spacer()
                }
                hint("仅控制当前运行状态，不改变登录启动设置。手机需开启无线调试，并授权这台 Mac。")
            }
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingSection(title: "登录启动") {
                if let value = store.panelAutostart {
                    HStack {
                        Text("在后台启动剪贴板面板")
                        Spacer()
                        Toggle("在后台启动剪贴板面板", isOn: Binding(get: { value }, set: { store.setAutostart(panel: $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(store.busy)
                    }
                }
                if let value = store.syncAutostart {
                    HStack {
                        Text("启动手机文字同步")
                        Spacer()
                        Toggle("启动手机文字同步", isOn: Binding(get: { value }, set: { store.setAutostart(sync: $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(store.busy)
                    }
                }
                if store.panelAutostart == nil || store.syncAutostart == nil {
                    HStack { hint("正在读取登录设置；读取失败时可重试。"); Spacer(); Button("重试") { store.phone("services") }.buttonStyle(RelayButtonStyle()).disabled(store.busy) }
                }
                hint("开关即时保存，下次登录生效。面板只在后台运行，不自动弹出。")
            }
            SettingSection(title: "呼出快捷键") {
                HStack(spacing: 12) {
                    Text("呼出面板")
                    Spacer()
                    Picker("组合键", selection: $draft.modifier) {
                        ForEach(PanelPreferences.modifiers, id: \.self) { Text($0) }
                    }.labelsHidden().frame(width: 180)
                    Picker("字母", selection: $draft.letter) {
                        ForEach(PanelPreferences.keyCodes.keys.sorted(), id: \.self) { Text($0) }
                    }.labelsHidden().frame(width: 65)
                }
                hint("修改后点击底部保存。快捷键被其他应用占用时，保留原设置。")
                HStack(spacing: 8) {
                    Keycap(text: "↩"); Text("粘贴")
                    Spacer().frame(width: 10)
                    Keycap(text: "⇧↩"); Text("纯文本粘贴")
                }.font(.system(size: 11)).foregroundStyle(RelayTheme.secondary)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingSection(title: "保留规则") {
                HStack {
                    Text("记录上限")
                    Spacer()
                    Text("\(draft.count) 条").monospacedDigit().foregroundStyle(RelayTheme.secondary)
                    Stepper("记录上限", value: $draft.count, in: 20...2000, step: 20).labelsHidden()
                }
                HStack {
                    Text("容量上限")
                    Spacer()
                    Text("\(draft.megabytes) MB").monospacedDigit().foregroundStyle(RelayTheme.secondary)
                    Stepper("容量上限", value: $draft.megabytes, in: 20...1000, step: 20).labelsHidden()
                }
                HStack {
                    Text("保留天数")
                    Spacer()
                    Picker("保留天数", selection: $draft.days) {
                        Text("不按时间清理").tag(0)
                        ForEach([7, 30, 90, 180, 365], id: \.self) { Text("\($0) 天").tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
                hint("置顶记录不自动清理。容量不足时先清普通记录，再清收藏；到期规则也适用于未置顶收藏。单条最多 20 MB。")
            }
            SettingSection(title: "清理历史") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("清理所有非置顶记录")
                        hint("包含未置顶收藏；确认后删除，无回收站。")
                    }
                    Spacer()
                    Button("清理…", role: .destructive) {
                        let affected = store.clips.filter { $0.pinnedAt == nil }
                        cleanupIDs = Set(affected.map(\.id))
                        affectedCount = affected.count; affectedBytes = affected.reduce(0) { $0 + $1.bytes }
                        confirmCleanup = true
                    }.buttonStyle(RelayButtonStyle(destructive: true)).disabled(store.clips.allSatisfy { $0.pinnedAt != nil })
                }
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingSection(title: "隐私暂停") {
                HStack(spacing: 12) {
                    Image(systemName: store.privacyPaused ? "hand.raised.fill" : "lock.shield")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(store.privacyPaused ? RelayTheme.warning : RelayTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.privacyPaused ? store.privacyLabel : "记录与同步可用").font(.system(size: 15, weight: .semibold))
                        hint("同时暂停本机历史、手机历史采集与文字同步。")
                    }
                }
                HStack(spacing: 8) {
                    Button("暂停 15 分钟") { store.setPrivacy(minutes: 15) }.buttonStyle(RelayButtonStyle())
                    Button("暂停 1 小时") { store.setPrivacy(minutes: 60) }.buttonStyle(RelayButtonStyle())
                    Button("手动恢复前暂停") { store.setPrivacy(minutes: nil) }.buttonStyle(RelayButtonStyle())
                }
                if store.privacyPaused {
                    Button("恢复记录与同步") { store.resumePrivacy() }.buttonStyle(RelayButtonStyle(prominent: true))
                }
            }
            SettingSection(title: "关于你的数据") {
                hint("暂停期间复制的内容不会在恢复时补录或补发；已经发出的传输可能完成。暂停状态在重启后仍然保留。")
                hint("历史以明文保存在本机，不上传云端。常见密码管理器的隐藏内容会被跳过，但不能识别所有敏感信息。")
                hint("退出面板不会停止独立的手机同步服务。停止同步请前往“手机连接”。")
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(RelayTheme.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }
    private func saveRules() {
        let affected = store.removalCandidates(using: draft)
        affectedCount = affected.count; affectedBytes = affected.reduce(0) { $0 + $1.bytes }
        if affected.isEmpty { store.applyPreferences(draft) } else { confirmRules = true }
    }
}
