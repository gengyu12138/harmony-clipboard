import Foundation

enum TextTransform: String, CaseIterable, Identifiable {
    case trim = "去首尾空白"
    case singleLine = "合成一行"
    case removeEmptyLines = "删除空行"
    case uniqueLines = "分行去重"
    var id: String { rawValue }
    func apply(to text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        switch self {
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .singleLine: return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        case .removeEmptyLines: return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .uniqueLines:
            var seen: Set<String> = []
            return lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
        }
    }
}

enum MergeSeparator: String, CaseIterable, Identifiable {
    case line = "换行", paragraph = "空行", space = "空格", tab = "制表符"
    var id: String { rawValue }
    var value: String {
        switch self { case .line: return "\n"; case .paragraph: return "\n\n"; case .space: return " "; case .tab: return "\t" }
    }
}

enum TextMerger {
    static let itemLimit = 50
    static let byteLimit = 256 * 1024
    static func combine(_ texts: [String], separator: MergeSeparator) throws -> String {
        guard texts.count <= itemLimit else { throw TextToolError(message: "一次最多合并 50 条文字。") }
        let bytes = texts.reduce(0) { $0 + $1.utf8.count } + max(0, texts.count - 1) * separator.value.utf8.count
        guard bytes <= byteLimit else { throw TextToolError(message: "合并结果超过 256 KB，请减少选择。") }
        return texts.joined(separator: separator.value)
    }
}
