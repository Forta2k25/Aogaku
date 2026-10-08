import XCTest
import UIKit
import FirebaseCore
import FirebaseAuth
@testable import Aogaku

final class AIDetectionResultTests: XCTestCase {
    func chunks(_ json: String) throws -> [AIEvidenceChunk] { try JSONDecoder().decode([AIEvidenceChunk].self, from: Data(json.utf8)) }
    func testNewChunkOffsetsRemoveOverlapButKeepRepeatedDistinctUnits() throws {
        let values = try chunks("""
        [{"chunkId":"000000","text":"親から子へ遺伝する。","method":"multimodal_ai","unitIndex":0,"locator":{"startChar":0,"endChar":10}},
         {"chunkId":"000001","text":"遺伝する。続き。","method":"multimodal_ai","unitIndex":0,"locator":{"startChar":5,"endChar":13}},
         {"chunkId":"000002","text":"親から子へ遺伝する。","method":"multimodal_ai","unitIndex":1,"locator":{"startChar":0,"endChar":10}}]
        """)
        XCTAssertEqual(AIDetectionResult.cleanText(values), "親から子へ遺伝する。続き。\n親から子へ遺伝する。")
    }
    func testOldVisionChunksReconstructWithoutReprocessing() throws {
        let values = try chunks("""
        [{"chunkId":"000000","text":"旧OCR本文の重なり","method":"vision_ocr","locator":{"imageIndex":1}},
         {"chunkId":"000001","text":"重なり続き","method":"vision_ocr","locator":{"imageIndex":1}}]
        """)
        XCTAssertEqual(AIDetectionResult.cleanText(values), "旧OCR本文の重なり続き")
        let result = AIDetectionResult(text: "旧OCR", method: "vision_ocr")
        XCTAssertTrue(result.detail.contains("保存済み結果"))
        XCTAssertTrue(result.tokenSentence.contains("取得できません"))
        XCTAssertTrue(result.costSentence().contains("取得できません"))
    }
    func testDifferentPDFPagesAndAudioSegmentsAreNotDeduplicated() throws {
        let values = try chunks("""
        [{"chunkId":"000000","text":"同じ本文","method":"pdf_text","locator":{"pageNumber":1}},
         {"chunkId":"000001","text":"同じ本文","method":"pdf_text","locator":{"pageNumber":2}}]
        """)
        XCTAssertEqual(AIDetectionResult.cleanText(values), "同じ本文\n同じ本文")
    }
    func testUsageCostAndFXPresentationUsesMeasuredValues() throws {
        let r = try JSONDecoder().decode(AIRecognitionMetadata.self, from: Data("""
        {"provider":"groq","model":"qwen/qwen3.8-27b","method":"multimodal_ai","processingMs":2800,"inputTokens":2940,"outputTokens":417,"totalTokens":3357,"estimatedCostUSD":0.00402,"pricingAsOf":"2026-10-08","pricingVersion":"v1"}
        """.utf8))
        let result = AIDetectionResult(text: "本文", recognition: r)
        XCTAssertEqual(result.tokenSentence, "Token: 入力2,940 / 出力417 / 合計3,357 tokens。")
        XCTAssertTrue(result.detail.contains("2.8秒"))
        XCTAssertTrue(result.costSentence(usdJPY: 150).contains("約¥0.60"))
        XCTAssertFalse(result.costSentence().contains("¥"))
        XCTAssertFalse(result.costSentence(usdJPY: -1).contains("¥"))
    }
    func testOldBackendIsRefusedBeforeImageCreateAndUpload() throws {
        XCTAssertThrowsError(try AIImagePipeline.requireCapability(["items": []]))
        let valid: [String: Any] = ["pipelineVersion": "image-ai-v2", "provider": "groq", "model": "qwen/qwen3.8-27b", "method": "multimodal_ai", "fallback": false]
        XCTAssertNoThrow(try AIImagePipeline.requireCapability(["inputCapabilities": ["image": valid]]))
        for (key, wrong) in [("provider", "google" as Any), ("model", "other" as Any), ("method", "vision_ocr" as Any), ("pipelineVersion", "input-v1" as Any), ("fallback", true as Any)] {
            var value = valid; value[key] = wrong
            XCTAssertThrowsError(try AIImagePipeline.requireCapability(["inputCapabilities": ["image": value]]))
        }
    }
    func testImageReceiptRequiresAIAndMetadataAbsenceDoesNotInventOCR() throws {
        let base = "{\"sourceId\":\"test\",\"sourceType\":\"image\",\"title\":\"test\",\"courseOfferingId\":\"2026:00004\",\"lectureId\":\"l\",\"dayID\":20734,\"status\":\"awaiting_upload\",\"rawVisibility\":\"private\",\"knowledgeVisibility\":\"private\""
        let old = try JSONDecoder().decode(AIRemoteSource.self, from: Data((base + "}").utf8))
        XCTAssertThrowsError(try AIImagePipeline.requireReceipt(old))
        let current = try JSONDecoder().decode(AIRemoteSource.self, from: Data((base + ",\"pipelineVersion\":\"image-ai-v2\"}").utf8))
        XCTAssertNoThrow(try AIImagePipeline.requireReceipt(current))
        let result = AIDetectionResult(text: "本文", method: "multimodal_ai", pipelineVersion: "image-ai-v2")
        XCTAssertFalse(result.detail.contains("OCR"))
        XCTAssertTrue(result.detail.contains("モデル情報未取得"))
    }
    func testEvidenceCannotMislabelOCRAsQwenButLegacyStillReads() throws {
        let old = try chunks("[{\"chunkId\":\"000000\",\"text\":\"OCR\",\"method\":\"vision_ocr\",\"locator\":{}}]")
        XCTAssertNoThrow(try AIImagePipeline.requireEvidence(pipelineVersion: "input-v1", recognition: nil, chunks: old))
        XCTAssertThrowsError(try AIImagePipeline.requireEvidence(pipelineVersion: "image-ai-v2", recognition: nil, chunks: old))
        let r = AIRecognitionMetadata(provider: "groq", model: "qwen/qwen3.8-27b", method: "multimodal_ai", pipelineVersion: "image-ai-v2")
        XCTAssertThrowsError(try AIImagePipeline.requireEvidence(pipelineVersion: "image-ai-v2", recognition: r, chunks: old))
        let values = try chunks("[{\"chunkId\":\"000000\",\"text\":\"AI本文\",\"method\":\"multimodal_ai\",\"locator\":{}}]")
        XCTAssertNoThrow(try AIImagePipeline.requireEvidence(pipelineVersion: "image-ai-v2", recognition: r, chunks: values))
        let viewResult = AIDetectionResult(text: "AI本文", recognition: r)
        XCTAssertTrue(viewResult.detail.contains("Groq / qwen/qwen3.8-27b"))
        XCTAssertFalse(viewResult.detail.contains("OCR"))
    }
    func testAudioCostHasDurationAndNoInventedTokens() {
        let r = AIRecognitionMetadata(provider: "groq", model: "whisper-large-v3-turbo", method: "groq_asr", audioDurationSeconds: 1112, billedAudioSeconds: 1112, estimatedCostUSD: 1112 / 3600 * 0.04)
        let result = AIDetectionResult(text: "講義本文", recognition: r)
        XCTAssertEqual(result.tokenSentence, "Token: 音声認識はtoken課金ではないため対象外です。")
        XCTAssertTrue(result.costSentence().contains("18分32秒"))
    }
    @MainActor func testAnonymousSessionPreservesExistingAccountAndCoalescesSignIn() async throws {
        let existing = AIInputSession(currentUID: { "existing-account" }, signIn: { XCTFail("Do not replace existing accounts"); return "new" })
        let existingUID = try await existing.ensure()
        XCTAssertEqual(existingUID, "existing-account")
        var count = 0
        let session = AIInputSession(currentUID: { nil }, signIn: { count += 1; try await Task.sleep(nanoseconds: 10_000_000); return "synthetic-anonymous" })
        async let one = session.ensure(); async let two = session.ensure()
        let ids = try await [one, two]
        XCTAssertEqual(ids, ["synthetic-anonymous", "synthetic-anonymous"]); XCTAssertEqual(count, 1)
    }
    @MainActor func testAnonymousDevInputToInlineEvidence() async throws {
        guard ProcessInfo.processInfo.environment["AOGAKU_RUN_DEV_E2E"] == "1" else { throw XCTSkip("Dev network test is opt-in") }
        guard let file = Bundle(for: Self.self).url(forResource: "detection-dev-context", withExtension: "json") else { throw XCTSkip("Prepare ignored Dev context first") }
        XCTAssertEqual(FirebaseCore.FirebaseApp.app()?.options.projectID, "forta-aogaku-dev")
        let c = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let uid = try await AIInputSession.shared.ensure()
        XCTAssertFalse(uid.isEmpty)
        let context = AIInputContext(ownerUID: uid, localCourseId: c["localCourseUUID"] as! String,
            classDocId: c["classDocId"] as? String, year: c["year"] as? Int, semester: "fall", dayID: c["dayID"] as! Int,
            localCourseUUID: c["localCourseUUID"] as? String, syllabusUrl: c["syllabusUrl"] as? String,
            courseName: "Synthetic detection class", teacherName: "架空の教員")
        let service = SourceIngestionService.shared, store = try service.store(uid: uid)
        let source = try store.stage(context: context, kind: .note, title: "iOS検出結果確認", mime: "text/plain", text: "カントを学ぶ。iOS Dev専用の架空の講義メモ。")
        try store.submit(context: context, snapshots: [AIChatSnapshot(id: UUID().uuidString, context: context, kind: "text", text: source.text, sourceIDs: [source.id], createdAt: Date())])
        service.resume(uid: uid)
        let end = Date().addingTimeInterval(120)
        var remote: AIRemoteSource?
        while Date() < end {
            await service.refreshSource(localID: source.id, uid: uid)
            remote = store.ledger.sources.first(where: { $0.id == source.id })?.remote
            if remote?.status == "ready" { break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let ready = try XCTUnwrap(remote); XCTAssertEqual(ready.status, "ready")
        let result = try await service.detectionResult(sourceId: ready.sourceId, uid: uid)
        XCTAssertEqual(result.text, source.text)
        let view = AIDetectionResultView(); view.show(result)
        XCTAssertEqual(view.displayedText, source.text); XCTAssertFalse(view.isHidden)
        let current = try XCTUnwrap(store.ledger.sources.first(where: { $0.id == source.id }))
        try await service.delete(current)
    }
    @MainActor func testFreshDevQwenEvidenceRendersActualProviderUsageAndCost() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "image-route-dev-results", withExtension: "json") else { throw XCTSkip("Dev result fixture is optional and never tracked") }
        let pages = try JSONDecoder().decode([AIEvidencePage].self, from: Data(contentsOf: url))
        XCTAssertEqual(pages.count, 2)
        for page in pages {
            try AIImagePipeline.requireEvidence(pipelineVersion: page.pipelineVersion, recognition: page.recognition, chunks: page.items)
            let result = AIDetectionResult(text: AIDetectionResult.cleanText(page.items), recognition: page.recognition, processingMs: page.processingMs, method: page.items.first?.method, pipelineVersion: page.pipelineVersion)
            let view = AIDetectionResultView(); view.show(result)
            XCTAssertFalse(view.displayedText.isEmpty)
            XCTAssertTrue(view.displayedDetail.contains("Groq / qwen/qwen3.8-27b"))
            XCTAssertFalse(view.displayedDetail.contains("OCR"))
            XCTAssertTrue(result.tokenSentence.contains("入力"))
            XCTAssertTrue(result.costSentence().contains("$"))
        }
    }
    @MainActor func testFreshProductionEvidenceRendersProviderUsageCostAndWhisper() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "image-route-production-results", withExtension: "json") else {
            throw XCTSkip("Production synthetic evidence is optional and never tracked")
        }
        let pages = try JSONDecoder().decode([AIEvidencePage].self, from: Data(contentsOf: url))
        XCTAssertEqual(pages.count, 3)
        for page in pages {
            let metadata = try XCTUnwrap(page.recognition)
            if page.pipelineVersion == "image-ai-v2" {
                try AIImagePipeline.requireEvidence(pipelineVersion: page.pipelineVersion, recognition: metadata, chunks: page.items)
                XCTAssertEqual(metadata.model, "qwen/qwen3.8-27b")
            } else {
                XCTAssertEqual(metadata.model, "whisper-large-v3-turbo")
                XCTAssertTrue(page.items.allSatisfy { $0.method == "groq_asr" })
            }
            let result = AIDetectionResult(text: AIDetectionResult.cleanText(page.items), recognition: metadata,
                processingMs: page.processingMs, method: page.items.first?.method, pipelineVersion: page.pipelineVersion)
            let view = AIDetectionResultView(); view.show(result)
            XCTAssertFalse(view.isHidden)
            XCTAssertFalse(view.displayedText.isEmpty)
            XCTAssertTrue(view.displayedDetail.contains(metadata.model ?? ""))
            let labels = view.arrangedSubviews.compactMap { $0 as? UILabel }
            let tokens = labels.first { $0.accessibilityIdentifier == "ai-detection-tokens" }
            let cost = labels.first { $0.accessibilityIdentifier == "ai-detection-cost" }
            XCTAssertEqual(tokens?.text, result.tokenSentence)
            XCTAssertTrue(cost?.text?.contains(result.costSentence()) == true)
            if metadata.method == "groq_asr" {
                XCTAssertTrue(tokens?.text?.contains("token課金ではないため対象外") == true)
            } else {
                XCTAssertTrue(tokens?.text?.contains("入力") == true)
                XCTAssertFalse(view.displayedDetail.contains("OCR"))
            }
        }
    }
    @MainActor func testInlineViewOnlyShowsFinalTextAndClearsOnDeletion() {
        let view = AIDetectionResultView()
        view.showState("AIが資料を読み取っています…")
        XCTAssertTrue(view.displayedText.contains("読み取っています"))
        view.show(AIDetectionResult(text: "親から子へ特徴が遺伝する。", method: "multimodal_ai"))
        XCTAssertEqual(view.displayedText, "親から子へ特徴が遺伝する。")
        XCTAssertFalse(view.displayedText.contains("rawText"))
        view.clear(); XCTAssertTrue(view.isHidden); XCTAssertEqual(view.displayedText, "")
    }
}
