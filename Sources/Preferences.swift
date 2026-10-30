import AppKit
import Carbon

struct PanelPreferences: Codable, Equatable {
    var count = 100
    var megabytes = 100
    var days = 0
    var letter = "X"
    var modifier = "Control"
    static let modifiers = ["Control", "Control+Option", "Control+Shift", "Command+Option"]
    static let keyCodes: [String: UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"N":45,"M":46]
    var keyCode: UInt32 { Self.keyCodes[letter] ?? UInt32(kVK_ANSI_X) }
    var modifierMask: UInt32 {
        switch modifier {
        case "Control+Option": return UInt32(controlKey | optionKey)
        case "Control+Shift": return UInt32(controlKey | shiftKey)
        case "Command+Option": return UInt32(cmdKey | optionKey)
        default: return UInt32(controlKey)
        }
    }
    var shortcutLabel: String { modifier + "+" + letter }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "panel.preferences"),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              (20...2000).contains(result.count), (20...1000).contains(result.megabytes),
              (0...365).contains(result.days), keyCodes[result.letter] != nil, modifiers.contains(result.modifier) else { return Self() }
        return result
    }
}

struct PrivacyState: Codable {
    var paused: Bool
    var until: Double?
    var generation: String? = UUID().uuidString
    var active: Bool { paused && (until == nil || until! > Date().timeIntervalSince1970) }
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HarmonyClipboard/privacy.json")
}

extension ClipboardStore {
    func applyPreferences(_ value: PanelPreferences) {
        guard changeHotkey?(value) == true else { message = "快捷键已被其他应用占用，设置未更改"; return }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "panel.preferences")
            preferences = value; hotkeyAvailable = true
            trimHistory()
            message = "设置已保存 · " + value.shortcutLabel + " 呼出"
        } catch { message = "设置保存失败：\(error.localizedDescription)" }
    }

    func setAutostart(panel: Bool? = nil, sync: Bool? = nil) {
        var value: [String: Bool] = [:]
        if let panel { value["panel_autostart"] = panel }
        if let sync { value["sync_autostart"] = sync }
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            phone("autostart", inputText: String(decoding: data, as: UTF8.self))
        } catch { message = "启动设置编码失败" }
    }
}
