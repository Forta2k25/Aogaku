#if DEBUG
import Foundation

struct LabRecognitionResult: Codable, Equatable {
    var rawText: String
    var normalizedText: String
    var structuredResult: String?
    var method: String
    var provider: String
    var model: String
    var processingMs: Double
    var warnings: [String]
    var error: String?
    var usage: LabTokenUsage? = nil
    var estimatedCost: LabEstimatedCost? = nil
    var characterCount: Int { normalizedText.count }
    static func failure(_ error: String, method: String, provider: String, model: String, started: Date) -> Self {
        Self(rawText: "", normalizedText: "", structuredResult: nil, method: method, provider: provider, model: model,
             processingMs: Date().timeIntervalSince(started) * 1000, warnings: [], error: error)
    }
}
struct LabComparison: Codable, Equatable {
    var method: String
    var results: [LabRecognitionResult]
    var ocrTextProvidedToAI: String?
    var finalEvidenceText: String
    var warnings: [String]
    var totalProcessingMs: Double? = nil
    /// Comparison preserves recognizers independently. No automatic transcript fusion or ingestion.
    static func audio(_ results: [LabRecognitionResult], method: String) -> Self {
        Self(method: method, results: results, ocrTextProvidedToAI: nil, finalEvidenceText: "", warnings: [], totalProcessingMs: results.reduce(0) { $0 + $1.processingMs })
    }
}
enum LabImageMode: String, CaseIterable { case ocr = "vision_ocr", ai = "vision_llm", combined = "vision_ocr_llm" }
enum LabAudioMode: String, CaseIterable { case apple = "apple_speech", groq = "groq_asr", combined = "apple_groq" }
#endif
