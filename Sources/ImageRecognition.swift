import AppKit
import VisionKit

enum ImageTextRecognition {
    @MainActor
    static func analyze(_ image: NSImage) async throws -> ImageAnalysis {
        var configuration = ImageAnalyzer.Configuration([.text])
        let supported = ImageAnalyzer.supportedTextRecognitionLanguages
        configuration.locales = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        return try await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration)
    }
}
