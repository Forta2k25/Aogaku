import Foundation

enum AIImagePipeline {
    static let version = "image-ai-v2"
    static let provider = "groq"
    static let model = "qwen/qwen3.8-27b"
    static let method = "multimodal_ai"
    static let unavailableMessage = "接続先はQwen画像AIに未対応です。画像は送信していません。Dev確認はAogaku-Dev Schemeを使用してください。本番はバックエンド更新が必要です。"
    static func requireCapability(_ response: [String: Any]) throws {
        let image = (response["inputCapabilities"] as? [String: Any])?["image"] as? [String: Any]
        if image?["pipelineVersion"] as? String == "image-auto-v1" {
            guard image?["method"] as? String == "auto_route", image?["fallback"] as? Bool == false,
                  image?["provider"] as? String == provider, image?["model"] as? String == model,
                  Set(image?["routes"] as? [String] ?? []) == Set(["vision_ocr", "multimodal_ai"]) else {
                throw AIInputError.message("接続先の画像Router仕様が一致しません")
            }
            return
        }
        guard image?["pipelineVersion"] as? String == version,
              image?["provider"] as? String == provider, image?["model"] as? String == model,
              image?["method"] as? String == method, image?["fallback"] as? Bool == false else {
            throw AIInputError.message(unavailableMessage)
        }
    }
    static func requireEvidence(pipelineVersion: String?, recognition: AIRecognitionMetadata?, chunks: [AIEvidenceChunk]) throws {
        if pipelineVersion == "image-auto-v1" || pipelineVersion == "pdf-auto-v1" {
            guard let r = recognition, r.pipelineVersion == pipelineVersion, r.method == "auto_route",
                  let routing = r.routing, !routing.pages.isEmpty, !chunks.isEmpty else {
                throw AIInputError.message("資料Routerの処理情報を取得できませんでした")
            }
            for chunk in chunks {
                guard let page = routing.pages.first(where: { p in
                    pipelineVersion == "pdf-auto-v1" ? p.pageNumber == chunk.locator.pageNumber : p.imageIndex == chunk.locator.imageIndex
                }), page.route == chunk.method, ["native_text", "vision_ocr", "multimodal_ai"].contains(page.route),
                  page.route != "multimodal_ai" || (page.provider == provider && page.model == model) else {
                    throw AIInputError.message("資料RouterのEvidenceと処理方式が一致しません")
                }
            }
            return
        }
        guard pipelineVersion == version else { return } // Stored legacy OCR remains readable.
        guard let r = recognition, r.provider == provider, r.model == model, r.method == method,
              r.pipelineVersion == version, !chunks.isEmpty, chunks.allSatisfy({ $0.method == method }) else {
            throw AIInputError.message("画像AIの処理情報が一致しません。OCR結果をQwen結果として表示しません。")
        }
    }
    static func requireReceipt(_ source: AIRemoteSource) throws {
        guard source.sourceType == "image", [version, "image-auto-v1"].contains(source.pipelineVersion ?? "") else {
            throw AIInputError.message(unavailableMessage)
        }
    }
}

struct AIRecognitionMetadata: Codable, Equatable {
    var provider: String
    var model: String
    var method: String
    var pipelineVersion: String?
    var processingMs: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var audioDurationSeconds: Double?
    var billedAudioSeconds: Double?
    var estimatedCostUSD: Double?
    var pricingAsOf: String?
    var pricingVersion: String?
    var routing: AIVisualRouting? = nil
}
struct AIVisualRouting: Codable, Equatable {
    var routerVersion: String
    var pages: [Page]
    var counts: [String: Int]
    var ocrUnits: Int
    var aiCostUSD: Double?
    var ocrCostUSD: Double
    var pricingAssumption: String
    struct Page: Codable, Equatable {
        var pageNumber: Int?
        var imageIndex: Int?
        var route: String
        var provider: String
        var model: String?
        var routingScore: Double
        var routingReason: [String]
        var nativeTextQuality: Double
        var ocrQuality: Double
        var visualComplexity: Double
        var inputTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var estimatedCostUSD: Double?
        var processingMs: Double
    }
}
struct AIEvidenceChunk: Decodable {
    var chunkId: String
    var text: String
    var method: String
    var unitIndex: Int?
    var locator: Locator
    struct Locator: Codable { var pageNumber: Int?; var imageIndex: Int?; var startMs: Int?; var endMs: Int?; var startChar: Int?; var endChar: Int? }
    var unitKey: String {
        if let unitIndex { return "unit:\(unitIndex)" }
        return "\(method):\(locator.pageNumber ?? -1):\(locator.imageIndex ?? -1):\(locator.startMs ?? -1):\(locator.endMs ?? -1)"
    }
}
struct AIEvidencePage: Decodable {
    var items: [AIEvidenceChunk]
    var status: String
    var nextCursor: String?
    var activeVersion: String?
    var recognition: AIRecognitionMetadata?
    var processingMs: Double?
    var pipelineVersion: String?
}
struct AIDetectionResult {
    var text: String
    var recognition: AIRecognitionMetadata?
    var processingMs: Double?
    var method: String?
    var pipelineVersion: String?
    // Reconstruct from the actual active-run chunks; no second copy of the text is stored.
    static func cleanText(_ chunks: [AIEvidenceChunk], pageHeaders: Bool = false) -> String {
        var result = "", previousKey: String?, previousEnd: Int?, unitText = ""
        for chunk in chunks.sorted(by: { $0.chunkId < $1.chunkId }) {
            if chunk.unitKey != previousKey {
                if !result.isEmpty { result += "\n" }
                if pageHeaders, let page = chunk.locator.pageNumber { result += "[p.\(page)]\n" }
                result += chunk.text; unitText = chunk.text; previousKey = chunk.unitKey; previousEnd = chunk.locator.endChar
                continue
            }
            var text = chunk.text
            if let start = chunk.locator.startChar, let end = previousEnd {
                // Server char offsets are UTF-16 (JavaScript), not Swift grapheme counts.
                let skip = min(max(0, end - start), text.utf16.count)
                text = String(decoding: text.utf16.dropFirst(skip), as: UTF16.self)
            } else {
                // Legacy chunks have no offsets. Their known window overlaps by <=200 UTF-16 units.
                let left = Array(unitText.utf16), right = Array(text.utf16)
                let maxOverlap = min(200, left.count, right.count)
                if maxOverlap > 0 {
                    for n in stride(from: maxOverlap, through: 1, by: -1) where Array(left.suffix(n)) == Array(right.prefix(n)) {
                        text = String(decoding: right.dropFirst(n), as: UTF16.self); break
                    }
                }
            }
            result += text; unitText += text
            if let end = chunk.locator.endChar { previousEnd = max(previousEnd ?? end, end) }
        }
        return result
    }
    var tokenSentence: String {
        if recognition?.method == "groq_asr" || method == "groq_asr" { return "Token: 音声認識はtoken課金ではないため対象外です。" }
        guard let r = recognition, let input = r.inputTokens, let output = r.outputTokens, let total = r.totalTokens else {
            return "Token: 利用量を取得できませんでした。"
        }
        let f = NumberFormatter(); f.locale = Locale(identifier: "ja_JP"); f.numberStyle = .decimal
        func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? String(v) }
        return "Token: 入力\(n(input)) / 出力\(n(output)) / 合計\(n(total)) tokens。"
    }
    func costSentence(usdJPY: Double? = nil) -> String {
        guard let r = recognition, let amount = r.estimatedCostUSD, amount.isFinite, amount >= 0 else { return "Cost: 推定処理コストを取得できませんでした。" }
        let usd = String(format: "$%.6f", locale: Locale(identifier: "en_US_POSIX"), amount)
        let yen = usdJPY.flatMap { rate -> String? in
            guard rate.isFinite, rate > 0 else { return nil }
            return String(format: "（約¥%.2f）", locale: Locale(identifier: "ja_JP"), amount * rate)
        } ?? ""
        let duration = r.audioDurationSeconds.map { "\(Int($0 / 60))分\(Int($0.truncatingRemainder(dividingBy: 60)))秒の音声処理で" } ?? ""
        let partial = method == "partial_audio" ? "（処理できた部分のみ）" : ""
        let breakdown = r.routing.map { route in
            let ai = route.aiCostUSD.map { String(format: "$%.6f", $0) } ?? "不明"
            return String(format: "\nAI %@ + OCR $%.6f（判定probeを含む・標準有料単価）", ai, route.ocrCostUSD)
        } ?? ""
        return "Cost: \(duration)推定処理コストは \(usd)\(yen)です。\(partial)\(breakdown)"
    }
    var routeSummary: String? {
        guard let routing = recognition?.routing else { return nil }
        return "処理: 本文抽出 \(routing.counts["native_text"] ?? 0)ページ / OCR \(routing.counts["vision_ocr"] ?? 0) / AI \(routing.counts["multimodal_ai"] ?? 0)\nOCR判定・処理: \(routing.ocrUnits)回"
    }
    var routeDiagnostics: String? {
        guard let routing = recognition?.routing else { return nil }
        return routing.pages.map { page in
            let label = ["native_text": "本文抽出", "vision_ocr": "OCR", "multimodal_ai": "AI"][page.route] ?? page.route
            return "\(page.pageNumber.map { "p.\($0)" } ?? "画像") \(label) ・ score \(String(format: "%.2f", page.routingScore))\n理由: \(page.routingReason.joined(separator: ", "))"
        }.joined(separator: "\n\n")
    }
    var detail: String {
        let model: String
        if let recognition {
            switch recognition.provider {
            case "groq", "mixed": model = "Groq / " + recognition.model
            case "google_vision": model = "Google Vision OCR / " + recognition.model
            case "pdfjs": model = "PDF本文抽出"
            default: model = recognition.model
            }
        }
        else if method == "vision_ocr" { model = "Google Vision OCR（保存済み結果）" }
        else if method == "multimodal_ai" || method == "vision_llm" { model = "画像AI（モデル情報未取得）" }
        else { model = method == "pdf_text" ? "PDF本文抽出" : "保存済み資料" }
        let ms = recognition?.processingMs ?? processingMs
        return model + (ms.map { String(format: " ・ %.1f秒", $0 / 1000) } ?? "")
    }
}
