import Foundation
@main struct RecognitionLabModelTests {
    static func main() throws {
        let apple = LabRecognitionResult(rawText: "親から子", normalizedText: "親から子", structuredResult: "{}", method: "apple_speech", provider: "apple", model: "ja-JP", processingMs: 1000, warnings: [], error: nil)
        let groq = LabRecognitionResult(rawText: "親から子へ遺伝", normalizedText: "親から子へ遺伝", structuredResult: "{}", method: "groq_asr", provider: "groq", model: "test", processingMs: 2000, warnings: [], error: nil)
        let r = LabComparison.audio([apple,groq], method: "apple_groq")
        precondition(r.results.count == 2 && r.results[0].rawText == apple.rawText && r.results[1].rawText == groq.rawText)
        precondition(r.finalEvidenceText.isEmpty, "Comparisons must not automatically fuse transcripts")
        precondition(apple.characterCount == 4)
        let encoded = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(LabComparison.self, from: encoded)
        precondition(decoded == r)
        let fail = LabRecognitionResult.failure("APPLE_PERMISSION_DENIED", method: "apple_speech", provider: "apple", model: "ja-JP", started: Date())
        precondition(fail.error != nil && fail.rawText.isEmpty && fail.processingMs >= 0)
        precondition(LabImageMode.allCases.map(\.rawValue) == ["vision_ocr", "vision_llm", "vision_ocr_llm"])
        print("Recognition Lab models: independent transcripts, Codable roundtrip, failures, character count, 3 modes PASS")
    }
}
