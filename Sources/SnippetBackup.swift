import Foundation

struct SnippetGroup: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
}

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var groupID: String?
    var title: String
    var text: String
}

struct SnippetLibrary: Codable {
    var groups: [SnippetGroup] = []
    var items: [Snippet] = []
}

struct SnippetBackup: Codable {
    let version: Int
    let library: SnippetLibrary
}

struct TextToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SnippetBackupCodec {
    static let libraryLimit = 2 * 1024 * 1024
    static let fileLimit = libraryLimit + 4096
    private struct Signature: Hashable {
        let groupID: String?
        let title: String
        let text: String
    }

    static func validate(_ library: SnippetLibrary) throws {
        let groups = Set(library.groups.map(\.id)), items = Set(library.items.map(\.id))
        guard groups.count == library.groups.count, items.count == library.items.count,
              Set(library.groups.map(\.name)).count == library.groups.count,
              library.groups.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              library.items.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.text.isEmpty
                  && $0.text.utf8.count <= 64 * 1024 && ($0.groupID == nil || groups.contains($0.groupID ?? "")) }) else {
            throw TextToolError(message: "片段数据无效：编号、分组或内容不符合要求，未导入任何内容。")
        }
        guard try JSONEncoder().encode(library).count <= libraryLimit else {
            throw TextToolError(message: "片段库超过 2 MB，原片段保留。")
        }
    }

    static func encode(_ library: SnippetLibrary) throws -> Data {
        try validate(library)
        return try JSONEncoder().encode(SnippetBackup(version: 1, library: library))
    }

    static func decode(_ data: Data) throws -> SnippetLibrary {
        guard data.count <= fileLimit else { throw TextToolError(message: "备份文件过大，未导入。") }
        let backup = try JSONDecoder().decode(SnippetBackup.self, from: data)
        guard backup.version == 1 else { throw TextToolError(message: "不支持这个备份版本，未导入。") }
        try validate(backup.library)
        return backup.library
    }

    static func merge(_ incoming: SnippetLibrary, into current: SnippetLibrary) throws -> (library: SnippetLibrary, items: Int, groups: Int) {
        try validate(current); try validate(incoming)
        var result = current, mapped: [String: String] = [:]
        var groupIDs = Set(current.groups.map(\.id)), itemIDs = Set(current.items.map(\.id))
        var groupsByName = Dictionary(uniqueKeysWithValues: current.groups.map { ($0.name, $0.id) })
        for group in incoming.groups {
            if let existing = groupsByName[group.name] { mapped[group.id] = existing }
            else {
                var id = group.id
                while groupIDs.contains(id) { id = UUID().uuidString }
                result.groups.append(SnippetGroup(id: id, name: group.name)); groupIDs.insert(id); mapped[group.id] = id
                groupsByName[group.name] = id
            }
        }
        var signatures = Set(current.items.map { Signature(groupID: $0.groupID, title: $0.title, text: $0.text) })
        for item in incoming.items {
            var imported = item
            if let group = item.groupID {
                guard let id = mapped[group] else { throw TextToolError(message: "备份分组不可用，未导入。") }
                imported.groupID = id
            }
            guard signatures.insert(Signature(groupID: imported.groupID, title: imported.title, text: imported.text)).inserted else { continue }
            while itemIDs.contains(imported.id) { imported.id = UUID().uuidString }
            itemIDs.insert(imported.id); result.items.append(imported)
        }
        try validate(result)
        return (result, result.items.count - current.items.count, result.groups.count - current.groups.count)
    }
}
