import AppKit

extension AppDelegate {
    @objc func showPhoneSettings() {
        guard !configuringPhone else { return }
        configuringPhone = true
        defer { configuringPhone = false }
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HarmonyClipboard/config.json")
        var endpoint = ""
        do {
            if FileManager.default.fileExists(atPath: configURL.path) {
                let data = try Data(contentsOf: configURL)
                guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let address = config["endpoint"] as? String else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                endpoint = address
            }
        } catch {
            store.message = "连接配置读取失败，未覆盖原文件：\(error.localizedDescription)"
            return
        }
        let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        let ip = NSTextField(string: parts.count == 2 ? String(parts[0]) : "")
        ip.placeholderString = "例如 192.168.1.100"
        ip.setAccessibilityLabel("手机 IP 地址")
        let port = NSTextField(string: parts.count == 2 ? String(parts[1]) : "")
        port.placeholderString = "无线调试页面显示的端口"
        port.setAccessibilityLabel("无线调试端口")
        let fields = NSStackView(views: [NSTextField(labelWithString: "手机 IPv4 地址"), ip,
                                      NSTextField(labelWithString: "无线调试端口"), port])
        fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 340, height: 110)
        ip.widthAnchor.constraint(equalToConstant: 340).isActive = true
        port.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let alert = NSAlert()
        alert.messageText = "手机连接设置"
        alert.informativeText = "手机和 Mac 需在同一局域网。请从手机“开发者选项 → 无线调试”填写当前 IP 和端口；端口变化后需在这里更新。保存会连接手机；登录自启由设置中的开关控制。"
        alert.accessoryView = fields
        alert.addButton(withTitle: "保存并连接")
        alert.addButton(withTitle: "取消")
        while alert.runModal() == .alertFirstButtonReturn {
            let address = ip.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let portText = port.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let octets = address.split(separator: ".", omittingEmptySubsequences: false)
            let validIP = octets.count == 4 && octets.allSatisfy {
                !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
                    && Int($0).map { (0...255).contains($0) } == true
                    && ($0.count == 1 || $0.first != "0")
            }
            if validIP, let number = Int(portText), (1...65535).contains(number),
               portText.allSatisfy({ $0.isASCII && $0.isNumber }) {
                store.phone("configure", inputText: "\(address):\(number)")
                return
            }
            alert.informativeText = "格式不正确：IP 必须为 4 段 0–255 的数字，端口为 1–65535。请填写无线调试页面上的当前值。"
        }
    }
}
