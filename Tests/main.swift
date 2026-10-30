import XCTest

let suites = [TextOperationTests.defaultTestSuite, BackupCodecTests.defaultTestSuite,
              ClipIndexTests.defaultTestSuite, SnippetStoreTests.defaultTestSuite,
              ImageGeometryTests.defaultTestSuite, ImageRecognitionTests.defaultTestSuite]
guard suites.allSatisfy({ $0.testCaseCount > 0 }) else {
    fatalError("测试发现失败，不能将空测试集算作通过")
}
let suite = XCTestSuite(name: "HarmonyClipboard Native")
for child in suites { suite.addTest(child) }
suite.run()
guard let result = suite.testRun else { fatalError("没有原生测试结果") }
print("NATIVE_TEST_RESULT executed=\(result.executionCount) failures=\(result.totalFailureCount) skipped=\(result.skipCount)")
exit(result.hasSucceeded && result.executionCount > 0 && result.skipCount == 0 ? 0 : 1)
