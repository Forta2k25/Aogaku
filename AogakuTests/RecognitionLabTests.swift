#if DEBUG
import XCTest
import Speech
@testable import Aogaku

final class RecognitionLabTests: XCTestCase {
    func testCostContractRoundtripAndCombinedDisplay() throws {
        let json = """
        {"method":"vision_ocr_llm","results":[
          {"rawText":"OCR","normalizedText":"OCR","method":"vision_ocr","provider":"google_cloud_vision","model":"DOCUMENT_TEXT_DETECTION","processingMs":1240,"warnings":[],"error":null,
           "estimatedCost":{"pricing":{"provider":"google_cloud_vision","model":"DOCUMENT_TEXT_DETECTION","pricingUnit":"thousand_images","inputPrice":1.5,"outputPrice":null,"currency":"USD","pricingAsOf":"2026-10-08","sourceURL":"https://cloud.google.com/vision/pricing"},"inputCostUSD":0.0015,"outputCostUSD":null,"estimatedCostUSD":0.0015,"imageUnits":1,"notes":["Free tier excluded"]}},
          {"rawText":"AI","normalizedText":"AI","method":"vision_ocr_llm","provider":"groq","model":"qwen/qwen3.8-27b","processingMs":830,"warnings":[],"error":null,
           "usage":{"promptTokens":2940,"completionTokens":417,"totalTokens":3357},
           "estimatedCost":{"pricing":{"provider":"groq","model":"qwen/qwen3.8-27b","pricingUnit":"million_tokens","inputPrice":0.8,"outputPrice":4,"currency":"USD","pricingAsOf":"2026-10-08","sourceURL":"https://console.groq.com/docs/model/qwen/qwen3.8-27b"},"inputCostUSD":0.002352,"outputCostUSD":0.001668,"estimatedCostUSD":0.004020,"notes":[]}}
        ],"ocrTextProvidedToAI":"OCR","finalEvidenceText":"AI","warnings":[],"totalProcessingMs":2070}
        """
        let value = try JSONDecoder().decode(LabComparison.self, from: Data(json.utf8))
        XCTAssertEqual(value.results[1].usage?.totalTokens, 3357)
        let display = LabCostPresentation.lines(for: value).joined(separator: "\n")
        for text in ["2,940 tokens", "$0.002352", "$0.001668", "$0.004020", "$0.001500", "Total estimated cost: $0.005520", "Pricing as of 2026-10-08", "Total: 2.070 s"] { XCTAssertTrue(display.contains(text), text) }
        let roundtrip = try JSONDecoder().decode(LabComparison.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(roundtrip, value)
    }
    func testHistoricalResultsRemainReadableAndMissingUsageIsNotZero() throws {
        let json = """
        {"method":"vision_llm","results":[{"rawText":"old","normalizedText":"old","method":"vision_llm","provider":"groq","model":"old-model","processingMs":100,"warnings":[],"error":null}],"finalEvidenceText":"old","warnings":[]}
        """
        let value = try JSONDecoder().decode(LabComparison.self, from: Data(json.utf8))
        XCTAssertNil(value.results[0].estimatedCost)
        let display = LabCostPresentation.lines(for: value).joined(separator: "\n")
        XCTAssertTrue(display.contains("Total estimated cost: N/A"))
        XCTAssertFalse(display.contains("Total estimated cost: $0.000000"))
    }
    func testAudioCostPresentationUsesSecondsInsteadOfTokens() {
        let rate = RecognitionPricing(provider: "groq", model: "whisper-large-v3-turbo", pricingUnit: "audio_hour", inputPrice: 0.04,
                                      currency: "USD", pricingAsOf: "2026-10-08", minimumBillingSeconds: 10, sourceURL: "https://console.groq.com/docs/speech-to-text")
        let cost = LabEstimatedCost(pricing: rate, inputCostUSD: 10 / 3600 * 0.04, estimatedCostUSD: 10 / 3600 * 0.04,
                                    audioDurationSeconds: 1, billedAudioSeconds: 10, durationSource: "Groq response duration", notes: [])
        let row = LabRecognitionResult(rawText: "test", normalizedText: "test", method: "groq_asr", provider: "groq", model: rate.model,
                                       processingMs: 100, warnings: [], estimatedCost: cost)
        let display = LabCostPresentation.lines(for: .audio([row], method: "groq_asr")).joined(separator: "\n")
        XCTAssertTrue(display.contains("Audio duration: 1.000 s"))
        XCTAssertTrue(display.contains("Billed duration (estimated): 10.000 s"))
        XCTAssertTrue(display.contains("Estimated cost: $0.000111"))
        XCTAssertFalse(display.contains("tokens"))
    }
    func testIncompleteCostShowsSubtotalWithoutClaimingTotalIsZero() {
        let ocr = LabRecognitionResult(rawText: "test", normalizedText: "test", method: "vision_ocr", provider: "google_cloud_vision", model: "DOCUMENT_TEXT_DETECTION",
                                       processingMs: 100, warnings: [], estimatedCost: LabEstimatedCost(estimatedCostUSD: 0.0015, notes: []))
        let failed = LabRecognitionResult.failure("LAB_PROVIDER_RATE_LIMIT", method: "vision_llm", provider: "groq", model: "test", started: Date())
        let value = LabComparison(method: "vision_ocr_llm", results: [ocr, failed], finalEvidenceText: "test", warnings: [])
        let display = LabCostPresentation.lines(for: value).joined(separator: "\n")
        XCTAssertTrue(display.contains("Total estimated cost: N/A"))
        XCTAssertTrue(display.contains("Known subtotal: $0.001500"))
    }
    func testAppleCostHasNoInventedExternalPrice() {
        let apple = LabRecognitionResult.failure("test", method: "apple_speech", provider: "apple", model: "ja-JP", started: Date())
        let display = LabCostPresentation.lines(for: .audio([apple], method: "apple_speech")).joined(separator: "\n")
        XCTAssertTrue(display.contains("External API cost: N/A"))
        XCTAssertFalse(display.contains("$0.000000"))
    }
    @MainActor func testAnonymousSessionCoalescesConcurrentCalls() async throws {
        var calls = 0
        let session = LabDevSession(currentUID: { nil }, signIn: {
            calls += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return "synthetic-device"
        })
        async let first = session.ensure()
        async let second = session.ensure()
        let values = try await [first, second]
        XCTAssertEqual(values, ["synthetic-device", "synthetic-device"])
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testExistingSessionIsNeverReplaced() async throws {
        let session = LabDevSession(currentUID: { "existing-dev-session" }, signIn: {
            XCTFail("Must not sign out or replace an existing Dev account")
            return "unexpected"
        })
        let value = try await session.ensure()
        XCTAssertEqual(value, "existing-dev-session")
    }
    @MainActor func testAnonymousFailureCanRetryWithoutCachingFailure() async throws {
        var calls = 0
        let session = LabDevSession(currentUID: { nil }, signIn: {
            calls += 1
            if calls == 1 { throw NSError(domain: "test", code: 1) }
            return "synthetic-device"
        })
        do { _ = try await session.ensure(); XCTFail("Must surface sign-in failure") } catch {}
        let value = try await session.ensure()
        XCTAssertEqual(value, "synthetic-device")
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testPermissionDenialDoesNotReadFileOrCallProvider() async {
        let recognizer = AppleLabSpeechRecognizer(authorization: { .denied })
        let result = await recognizer.recognize(file: URL(fileURLWithPath: "/nonexistent/lab.wav"), onDeviceOnly: true)
        XCTAssertEqual(result.error, "APPLE_PERMISSION_DENIED_OR_RESTRICTED")
        XCTAssertEqual(result.method, "apple_speech")
        XCTAssertTrue(result.rawText.isEmpty)
        XCTAssertGreaterThanOrEqual(result.processingMs, 0)
    }
    @MainActor func testConcurrentAuthorizationCannotOverwriteContinuation() async {
        let recognizer = AppleLabSpeechRecognizer(authorization: {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return .restricted
        })
        let first = Task { await recognizer.recognize(file: URL(fileURLWithPath: "/nonexistent/lab.wav"), onDeviceOnly: true) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = await recognizer.recognize(file: URL(fileURLWithPath: "/nonexistent/lab.wav"), onDeviceOnly: true)
        XCTAssertEqual(second.error, "APPLE_ALREADY_RUNNING")
        let original = await first.value
        XCTAssertEqual(original.error, "APPLE_PERMISSION_DENIED_OR_RESTRICTED")
    }
    func testAudioComparisonPreservesSuccessWhenOtherRecognizerFails() throws {
        let apple = LabRecognitionResult.failure("APPLE_PERMISSION_DENIED", method: "apple_speech", provider: "apple", model: "ja-JP", started: Date())
        let groq = LabRecognitionResult(rawText: "親から子へ遺伝", normalizedText: "親から子へ遺伝", structuredResult: "{\"segments\":[]}", method: "groq_asr", provider: "groq", model: "test", processingMs: 500, warnings: [], error: nil)
        let comparison = LabComparison.audio([apple, groq], method: "apple_groq")
        XCTAssertEqual(comparison.results[0].error, "APPLE_PERMISSION_DENIED")
        XCTAssertEqual(comparison.results[1].normalizedText, "親から子へ遺伝")
        XCTAssertTrue(comparison.finalEvidenceText.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(LabComparison.self, from: JSONEncoder().encode(comparison)), comparison)
    }
}
#endif
