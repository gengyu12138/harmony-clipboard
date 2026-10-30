import Foundation
import XCTest

enum TestFixtures {
    static var library: SnippetLibrary {
        SnippetLibrary(groups: [SnippetGroup(id: "group-work", name: "工作")],
                       items: [Snippet(id: "item-hello", groupID: "group-work", title: "问候", text: "你好，世界 👋\n第二行")])
    }
    static func image(_ id: String, time: Double = 0) -> Clip {
        Clip(id: id, file: id + ".image", mime: "public.png", source: "PRIVATE_SOURCE",
             date: Date(timeIntervalSince1970: time), bytes: 128)
    }
}

final class TextOperationTests: XCTestCase {
    func testTrimKeepsInternalWindowsLineEndings() {
        XCTAssertEqual(TextTransform.trim.apply(to: " \t甲\r\n乙 \n"), "甲\r\n乙")
    }
    func testSingleLineHandlesChineseAndMixedLineEndings() {
        XCTAssertEqual(TextTransform.singleLine.apply(to: " 甲 \r\n\r\n 乙\t\r丙 "), "甲 乙 丙")
    }
    func testRemoveEmptyLinesPreservesIndentation() {
        XCTAssertEqual(TextTransform.removeEmptyLines.apply(to: "  alpha\n \t\n    beta\n"), "  alpha\n    beta")
    }
    func testUniqueLinesKeepsOrderAndCase() {
        XCTAssertEqual(TextTransform.uniqueLines.apply(to: "甲\nA\n甲\na\nA"), "甲\nA\na")
    }
    func testEmptyTransforms() {
        for action in TextTransform.allCases { XCTAssertEqual(action.apply(to: ""), "") }
    }
    func testAllMergeSeparatorsKeepSelectionOrder() throws {
        let values = ["第三", "first", "第二"]
        XCTAssertEqual(try TextMerger.combine(values, separator: .line), "第三\nfirst\n第二")
        XCTAssertEqual(try TextMerger.combine(values, separator: .paragraph), "第三\n\nfirst\n\n第二")
        XCTAssertEqual(try TextMerger.combine(values, separator: .space), "第三 first 第二")
        XCTAssertEqual(try TextMerger.combine(values, separator: .tab), "第三\tfirst\t第二")
    }
    func testEmptyAndSingleMergeSupportPreviewReset() throws {
        XCTAssertEqual(try TextMerger.combine([], separator: .line), "")
        XCTAssertEqual(try TextMerger.combine(["一条"], separator: .line), "一条")
    }
    func testMergeSelectionLimit() throws {
        XCTAssertEqual(try TextMerger.combine(Array(repeating: "x", count: 50), separator: .space).split(separator: " ").count, 50)
        XCTAssertThrowsError(try TextMerger.combine(Array(repeating: "x", count: 51), separator: .line))
    }
    func testMergeExactByteLimitAndOverflow() throws {
        let limit = TextMerger.byteLimit
        XCTAssertEqual(try TextMerger.combine([String(repeating: "a", count: limit)], separator: .line).utf8.count, limit)
        XCTAssertThrowsError(try TextMerger.combine([String(repeating: "a", count: limit + 1)], separator: .line))
    }
    func testMergeCountsSeparatorBytes() throws {
        let prefix = String(repeating: "a", count: TextMerger.byteLimit - 2)
        XCTAssertEqual(try TextMerger.combine([prefix, "b"], separator: .line).utf8.count, TextMerger.byteLimit)
        XCTAssertThrowsError(try TextMerger.combine([prefix, "b"], separator: .paragraph))
    }
    func testMergeLimitUsesUTF8RatherThanCharacterCount() throws {
        let emojis = String(repeating: "😀", count: TextMerger.byteLimit / 4)
        XCTAssertEqual(try TextMerger.combine([emojis], separator: .line).utf8.count, TextMerger.byteLimit)
        XCTAssertThrowsError(try TextMerger.combine([emojis, "中"], separator: .space))
    }
}

final class BackupCodecTests: XCTestCase {
    func testUnicodeBackupRoundTrip() throws {
        let library = TestFixtures.library
        let restored = try SnippetBackupCodec.decode(SnippetBackupCodec.encode(library))
        XCTAssertEqual(restored.groups, library.groups)
        XCTAssertEqual(restored.items, library.items)
    }
    func testEmptyLibraryRoundTrip() throws {
        let restored = try SnippetBackupCodec.decode(SnippetBackupCodec.encode(SnippetLibrary()))
        XCTAssertTrue(restored.groups.isEmpty)
        XCTAssertTrue(restored.items.isEmpty)
    }
    func testUnknownVersionRejected() throws {
        let data = try JSONEncoder().encode(SnippetBackup(version: 2, library: TestFixtures.library))
        XCTAssertThrowsError(try SnippetBackupCodec.decode(data))
    }
    func testMalformedJSONAndMissingEnvelopeRejected() {
        XCTAssertThrowsError(try SnippetBackupCodec.decode(Data("not JSON".utf8)))
        XCTAssertThrowsError(try SnippetBackupCodec.decode(Data(#"{"groups":[],"items":[]}"#.utf8)))
    }
    func testDuplicateIdentifiersAndGroupNamesRejected() {
        var duplicate = TestFixtures.library
        duplicate.items.append(duplicate.items[0])
        XCTAssertThrowsError(try SnippetBackupCodec.validate(duplicate))
        duplicate = TestFixtures.library
        duplicate.groups.append(duplicate.groups[0])
        XCTAssertThrowsError(try SnippetBackupCodec.validate(duplicate))
        duplicate.groups[1].id = "different-id"
        XCTAssertThrowsError(try SnippetBackupCodec.validate(duplicate))
    }
    func testEmptyRequiredFieldsRejected() {
        for field in ["id", "title", "text", "group-name"] {
            var value = TestFixtures.library
            switch field {
            case "id": value.items[0].id = " "
            case "title": value.items[0].title = " \n"
            case "text": value.items[0].text = ""
            default: value.groups[0].name = " "
            }
            XCTAssertThrowsError(try SnippetBackupCodec.validate(value), field)
        }
    }
    func testOrphanGroupRejected() {
        var value = TestFixtures.library
        value.items[0].groupID = "missing-group"
        XCTAssertThrowsError(try SnippetBackupCodec.validate(value))
    }
    func testSnippetByteBoundary() throws {
        var value = TestFixtures.library
        value.items[0].text = String(repeating: "a", count: 64 * 1024)
        XCTAssertNoThrow(try SnippetBackupCodec.validate(value))
        value.items[0].text += "中"
        XCTAssertThrowsError(try SnippetBackupCodec.validate(value))
    }
    func testTotalCapacityRejectedWithoutMutatingCurrentLibrary() {
        let current = TestFixtures.library
        let incoming = SnippetLibrary(items: (0..<33).map { Snippet(id: "large-\($0)", title: "大片段\($0)", text: String(repeating: "x", count: 64 * 1024)) })
        XCTAssertThrowsError(try SnippetBackupCodec.merge(incoming, into: current))
        XCTAssertEqual(current.items, TestFixtures.library.items)
    }
    func testMatchingGroupNamesMapToExistingIdentifiers() throws {
        let current = TestFixtures.library
        let incoming = SnippetLibrary(groups: [SnippetGroup(id: "foreign-group", name: "工作")],
                                     items: [Snippet(id: "new", groupID: "foreign-group", title: "新片段", text: "新内容")])
        let result = try SnippetBackupCodec.merge(incoming, into: current)
        XCTAssertEqual(result.groups, 0)
        XCTAssertEqual(result.items, 1)
        XCTAssertEqual(result.library.items.last?.groupID, "group-work")
    }
    func testIdentifierCollisionsPreserveBothLibrariesAndReferences() throws {
        let current = TestFixtures.library
        let incoming = SnippetLibrary(groups: [SnippetGroup(id: "group-work", name: "家庭")],
                                     items: [Snippet(id: "item-hello", groupID: "group-work", title: "另一个", text: "保留新内容")])
        let result = try SnippetBackupCodec.merge(incoming, into: current)
        XCTAssertEqual(result.library.items.first, current.items.first)
        XCTAssertEqual(Set(result.library.items.map(\.id)).count, 2)
        XCTAssertEqual(Set(result.library.groups.map(\.id)).count, 2)
        XCTAssertEqual(result.library.items.last?.groupID, result.library.groups.last?.id)
        XCTAssertNotEqual(result.library.items.last?.id, "item-hello")
        XCTAssertNoThrow(try SnippetBackupCodec.validate(result.library))
    }
    func testRepeatedImportIsIdempotentEvenAfterRenumbering() throws {
        let incoming = SnippetLibrary(groups: [SnippetGroup(id: "group-work", name: "家庭")],
                                     items: [Snippet(id: "item-hello", groupID: "group-work", title: "另一个", text: "保留新内容")])
        let first = try SnippetBackupCodec.merge(incoming, into: TestFixtures.library)
        let second = try SnippetBackupCodec.merge(incoming, into: first.library)
        XCTAssertEqual(second.items, 0)
        XCTAssertEqual(second.groups, 0)
        XCTAssertEqual(second.library.items, first.library.items)
        XCTAssertEqual(second.library.groups, first.library.groups)
    }
    func testSameTextInDifferentTitlesOrGroupsRemainsDistinct() throws {
        let original = TestFixtures.library.items[0]
        let incoming = SnippetLibrary(groups: [SnippetGroup(id: "other", name: "其他")],
                                     items: [Snippet(id: "different-title", groupID: "other", title: "新标题", text: original.text),
                                             Snippet(id: "ungrouped", title: original.title, text: original.text)])
        let result = try SnippetBackupCodec.merge(incoming, into: TestFixtures.library)
        XCTAssertEqual(result.items, 2)
        XCTAssertEqual(result.library.items.count, 3)
    }
}

final class ClipIndexTests: XCTestCase {
    func testLegacyRecordDecodesWithoutImageText() throws {
        let legacy = Data(#"{"id":"legacy","text":"hello","source":"Mac","date":0,"bytes":5,"favorite":false}"#.utf8)
        let clip = try JSONDecoder().decode(Clip.self, from: legacy)
        XCTAssertNil(clip.imageText)
        XCTAssertEqual(clip.recordedDevices, ["Mac"])
        XCTAssertEqual(clip.text, "hello")
        XCTAssertEqual(clip.date, Date(timeIntervalSinceReferenceDate: 0))
    }
    func testLegacyPhoneImageAndExplicitDevices() {
        var clip = TestFixtures.image("phone")
        clip.source = "手机截图"
        XCTAssertEqual(clip.recordedDevices, ["手机"])
        clip.devices = ["Mac", "手机"]
        XCTAssertEqual(clip.deviceLabel, "Mac · 手机")
    }
    func testFullTextAndSourceSearchAreCaseInsensitive() {
        let clip = Clip(id: "text", text: String(repeating: "a", count: 500) + "ENDMARK",
                        source: "TextEdit", date: Date(), bytes: 507)
        XCTAssertTrue(clip.matches("endmark"))
        XCTAssertTrue(clip.matches("TEXTEDIT"))
        XCTAssertFalse(clip.matches("not-present"))
        XCTAssertTrue(clip.matches(""))
    }
    func testImageTextSearchAndRoundTrip() throws {
        var clips = [TestFixtures.image("image")]
        XCTAssertTrue(ImageTextIndex.record("合同 发票 TOTAL 123", for: "image", in: &clips))
        XCTAssertTrue(clips[0].matches("发票"))
        XCTAssertTrue(clips[0].matches("total"))
        let decoded = try JSONDecoder().decode([Clip].self, from: JSONEncoder().encode(clips))
        XCTAssertEqual(decoded[0].imageText, "合同 发票 TOTAL 123")
        XCTAssertEqual(decoded[0].date, clips[0].date)
        XCTAssertEqual(decoded[0].bytes, 128)
    }
    func testPerImageLimit() {
        var clips = [TestFixtures.image("image")]
        ImageTextIndex.record(String(repeating: "a", count: ImageTextIndex.entryLimit + 1), for: "image", in: &clips)
        XCTAssertEqual(clips[0].imageText?.utf8.count, ImageTextIndex.entryLimit)
    }
    func testChineseUTF8BoundaryIsNotCorrupted() {
        let prefix = String(repeating: "a", count: ImageTextIndex.entryLimit - 1)
        var clips = [TestFixtures.image("image")]
        ImageTextIndex.record(prefix + "中", for: "image", in: &clips)
        XCTAssertEqual(clips[0].imageText, prefix)
        XCTAssertFalse(clips[0].imageText?.contains("�") == true)
    }
    func testEmojiUTF8BoundaryIsNotCorrupted() {
        let prefix = String(repeating: "a", count: ImageTextIndex.entryLimit - 2)
        var clips = [TestFixtures.image("image")]
        ImageTextIndex.record(prefix + "😀", for: "image", in: &clips)
        XCTAssertEqual(clips[0].imageText, prefix)
    }
    func testGlobalBudgetEvictsOldestRecordRatherThanArrayPosition() {
        var clips = (0..<33).reversed().map { TestFixtures.image("image-\($0)", time: Double($0)) }
        let text = String(repeating: "x", count: ImageTextIndex.entryLimit)
        for index in 0..<33 { ImageTextIndex.record(text, for: "image-\(index)", in: &clips) }
        XCTAssertNil(clips.first { $0.id == "image-0" }?.imageText)
        XCTAssertEqual(clips.reduce(0) { $0 + ($1.imageText?.utf8.count ?? 0) }, ImageTextIndex.totalLimit)
        XCTAssertNotNil(clips.first { $0.id == "image-32" }?.imageText)
    }
    func testReopenedOldImageRemainsIndexedAtBudgetLimit() {
        var clips = (0..<33).map { TestFixtures.image("image-\($0)", time: Double($0)) }
        let text = String(repeating: "x", count: ImageTextIndex.entryLimit)
        for index in 0..<33 { ImageTextIndex.record(text, for: "image-\(index)", in: &clips) }
        ImageTextIndex.record(text, for: "image-0", in: &clips)
        XCTAssertNotNil(clips[0].imageText)
        XCTAssertNil(clips[1].imageText)
    }
    func testUnknownIdentifierAndTextRecordsAreNotIndexed() {
        var clips = [Clip(id: "text", text: "原文字", source: "Mac", date: Date(), bytes: 9)]
        XCTAssertFalse(ImageTextIndex.record("新内容", for: "missing", in: &clips))
        XCTAssertFalse(ImageTextIndex.record("新内容", for: "text", in: &clips))
        XCTAssertNil(clips[0].imageText)
        XCTAssertEqual(clips[0].text, "原文字")
    }
    func testIdenticalIndexResultDoesNotRequestAnotherSave() {
        var clips = [TestFixtures.image("image")]
        XCTAssertTrue(ImageTextIndex.record("正文", for: "image", in: &clips))
        XCTAssertFalse(ImageTextIndex.record("正文", for: "image", in: &clips))
    }
    func testIndexDisappearsWithItsHistoryRecord() throws {
        var clips = [TestFixtures.image("image")]
        ImageTextIndex.record("unique-index", for: "image", in: &clips)
        clips.removeAll { $0.id == "image" }
        let restored = try JSONDecoder().decode([Clip].self, from: JSONEncoder().encode(clips))
        XCTAssertFalse(restored.contains { $0.matches("unique-index") })
    }
    func testListTextRetainsNewlinesAndOmitsMetadata() {
        let clip = Clip(id: "text", text: "第一行\n第二行", source: "PRIVATE_SOURCE", date: Date(timeIntervalSince1970: 0), bytes: 19, devices: ["Mac"])
        XCTAssertEqual(clip.listPreview, "第一行\n第二行")
        XCTAssertFalse(clip.listPreview.contains("PRIVATE_SOURCE"))
        XCTAssertFalse(clip.listPreview.contains("Mac"))
        XCTAssertFalse(clip.listPreview.contains("1970"))
    }
    func testImageListUsesRecognizedTextOrNeutralLabel() {
        var clip = TestFixtures.image("image")
        XCTAssertEqual(clip.listPreview, "图片")
        clip.imageText = "识别的第一行\n第二行"
        XCTAssertEqual(clip.listPreview, "识别的第一行\n第二行")
    }
    func testListPreviewLimitDoesNotTruncateOriginalContent() {
        let text = String(repeating: "字", count: 1000)
        let clip = Clip(id: "text", text: text, source: "Mac", date: Date(), bytes: text.utf8.count)
        XCTAssertEqual(clip.listPreview.count, 800)
        XCTAssertEqual(clip.text, text)
    }
    func testWhitespaceOnlyRecordsHaveVisibleContentHint() {
        let clip = Clip(id: "blank", text: " \n\t", source: "Mac", date: Date(), bytes: 3)
        XCTAssertEqual(clip.listPreview, "空白文字（3 字符）")
        XCTAssertEqual(clip.text, " \n\t")
    }
    func testWhitespaceOCRDoesNotCreateBlankImageRows() {
        var clip = TestFixtures.image("image")
        clip.imageText = " \n\t"
        XCTAssertEqual(clip.listPreview, "图片")
    }
}
