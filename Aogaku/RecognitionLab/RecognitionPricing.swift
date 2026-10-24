#if DEBUG
import Foundation

/// USD rates arrive with the Dev result. The UI never maintains its own Groq/Vision price table.
struct RecognitionPricing: Codable, Equatable {
    var provider: String
    var model: String
    var pricingUnit: String
    var inputPrice: Double?
    var outputPrice: Double?
    var currency: String
    var pricingAsOf: String
    var minimumBillingSeconds: Double?
    var freeMonthlyUnits: Int?
    var volumeTiers: [VolumeTier]?
    var sourceURL: String
    struct VolumeTier: Codable, Equatable { var fromUnit: Int; var pricePerThousand: Double }
    static let appleSpeech = RecognitionPricing(provider: "apple", model: "SFSpeechRecognizer ja-JP", pricingUnit: "external_api_unpriced",
        inputPrice: nil, outputPrice: nil, currency: "USD", pricingAsOf: "2026-10-08", sourceURL: "https://developer.apple.com/documentation/speech")
}
struct LabTokenUsage: Codable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
}
struct LabEstimatedCost: Codable, Equatable {
    var pricing: RecognitionPricing?
    var inputCostUSD: Double?
    var outputCostUSD: Double?
    var estimatedCostUSD: Double?
    var audioDurationSeconds: Double?
    var billedAudioSeconds: Double?
    var durationSource: String?
    var imageUnits: Int?
    var notes: [String]
}

enum LabCostPresentation {
    private static func usd(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "N/A" }
        return String(format: "$%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func tokens(_ value: Int?) -> String {
        guard let value else { return "N/A" }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: value)) ?? String(value)) tokens"
    }
    private static func seconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "N/A" }
        return String(format: "%.3f s", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    static func lines(for comparison: LabComparison) -> [String] {
        var lines = ["\n--- Usage / Estimated cost ---", "推定APIコスト・実際の請求額ではありません（USD）。Functions／通信等の費用は含みません。"]
        for result in comparison.results {
            lines += ["\nModel: \(result.model)"]
            if result.provider == "apple" {
                lines += ["External API cost: N/A", "Pricing as of \(RecognitionPricing.appleSpeech.pricingAsOf)", "Apple Speechの従量料金を推定していません。"]
                continue
            }
            if result.provider == "groq" && result.method != "groq_asr" {
                lines += ["Usage (Groq API response)", "Input: \(tokens(result.usage?.promptTokens))", "Output: \(tokens(result.usage?.completionTokens))", "Total: \(tokens(result.usage?.totalTokens))"]
            }
            if let cost = result.estimatedCost {
                if let pricing = cost.pricing {
                    lines += ["Pricing as of \(pricing.pricingAsOf)", "Pricing unit: \(pricing.pricingUnit)"]
                    if pricing.pricingUnit == "million_tokens" {
                        lines += ["Input rate: \(usd(pricing.inputPrice)) / 1M tokens", "Output rate: \(usd(pricing.outputPrice)) / 1M tokens",
                                  "Input cost: \(usd(cost.inputCostUSD))", "Output cost: \(usd(cost.outputCostUSD))", "AI total: \(usd(cost.estimatedCostUSD))"]
                    } else if pricing.pricingUnit == "audio_hour" {
                        lines += ["Audio duration: \(seconds(cost.audioDurationSeconds))", "Billed duration (estimated): \(seconds(cost.billedAudioSeconds))",
                                  "Duration source: \(cost.durationSource ?? "N/A")", "Rate: \(usd(pricing.inputPrice)) / audio hour", "Estimated cost: \(usd(cost.estimatedCostUSD))"]
                    } else {
                        lines += ["OCR: \(usd(cost.estimatedCostUSD))", "OCRは標準有料tierでの推定。月間無料枠・数量割引は未反映（実額は$0の場合もあります）。"]
                    }
                } else { lines += ["Pricing as of N/A", "Estimated cost: N/A（返却modelの料金が未登録）"] }
                lines += cost.notes
            } else { lines += ["Pricing as of N/A", "Estimated cost: N/A（usage／料金情報なし。$0とは扱いません）"] }
        }
        let external = comparison.results.filter { $0.provider != "apple" }
        if !external.isEmpty {
            let amounts = external.map { $0.estimatedCost?.estimatedCostUSD }
            if amounts.allSatisfy({ $0 != nil }) {
                lines += ["\nTotal estimated cost: \(usd(amounts.compactMap { $0 }.reduce(0, +)))"]
                if external.contains(where: { $0.provider == "google_cloud_vision" }) { lines += ["TotalもOCR標準有料tierを使用（無料枠・割引未反映）。"] }
            } else {
                lines += ["\nTotal estimated cost: N/A（不明な処理コストあり）", "Known subtotal: \(usd(amounts.compactMap { $0 }.reduce(0, +)))"]
            }
        }
        lines += ["\n--- Processing ---"]
        for result in comparison.results {
            lines += ["\(result.method): \(seconds(result.processingMs / 1000))"]
        }
        lines += ["Total: \(seconds(comparison.totalProcessingMs.map { $0 / 1000 } ?? comparison.results.reduce(0) { $0 + $1.processingMs } / 1000))"]
        return lines
    }
}
#endif
