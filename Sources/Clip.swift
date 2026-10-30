import Foundation

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
    var imageText: String? = nil
    var isImage: Bool { file != nil }
    var recordedDevices: [String] { devices ?? (["鸿蒙手机", "手机截图"].contains(source) ? ["手机"] : ["Mac"]) }
    var deviceLabel: String { recordedDevices.joined(separator: " · ") }
    var title: String { text.map { String($0.prefix(180)).replacingOccurrences(of: "\n", with: " ") } ?? "图片 · \(source)" }
    func matches(_ query: String) -> Bool {
        query.isEmpty || (text ?? title).localizedCaseInsensitiveContains(query)
            || source.localizedCaseInsensitiveContains(query) || imageText?.localizedCaseInsensitiveContains(query) == true
    }
}

enum ImageTextIndex {
    static let entryLimit = 32 * 1024
    static let totalLimit = 1024 * 1024

    @discardableResult
    static func record(_ text: String, for id: String, in clips: inout [Clip]) -> Bool {
        guard let index = clips.firstIndex(where: { $0.id == id && $0.isImage }) else { return false }
        // Cut at a UTF-8 boundary so indexing a large result never introduces replacement characters.
        var prefix = Data(text.utf8.prefix(entryLimit))
        var bounded = String(data: prefix, encoding: .utf8)
        while bounded == nil && !prefix.isEmpty {
            prefix.removeLast(); bounded = String(data: prefix, encoding: .utf8)
        }
        guard let value = bounded, clips[index].imageText != value else { return false }
        clips[index].imageText = value
        var bytes = clips.reduce(0) { $0 + ($1.imageText?.utf8.count ?? 0) }
        for old in clips.indices.sorted(by: { clips[$0].date < clips[$1].date }) where old != index && bytes > totalLimit {
            bytes -= clips[old].imageText?.utf8.count ?? 0
            clips[old].imageText = nil
        }
        return true
    }
}
