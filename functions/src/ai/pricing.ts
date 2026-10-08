// Provider rates are snapshots, never client-side token estimates.
export const RECOGNITION_PRICING = {
  image: {provider: "groq", model: "qwen/qwen3.8-27b", pricingUnit: "million_tokens", inputPricePerMillionTokens: 0.80, outputPricePerMillionTokens: 4.00},
  audio: {provider: "groq", model: "whisper-large-v3-turbo", pricingUnit: "audio_hour", audioPricePerHour: 0.04, minimumBillingSeconds: 10},
  currency: "USD", pricingAsOf: "2026-10-08", pricingVersion: "groq-2026-10-08-v1"
} as const;
export interface RecognitionMetadata {
  provider: string; model: string; method: string; pipelineVersion: string; processingMs: number;
  inputTokens: number | null; outputTokens: number | null; totalTokens: number | null;
  audioDurationSeconds: number | null; billedAudioSeconds: number | null;
  estimatedCostUSD: number | null; pricingAsOf: string; pricingVersion: string;
}
function token(v: unknown): number | null { return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null; }
export function imageUsage(usage: any, model: string, processingMs: number): RecognitionMetadata {
  const inputTokens = token(usage?.prompt_tokens), outputTokens = token(usage?.completion_tokens), totalTokens = token(usage?.total_tokens);
  const rate = RECOGNITION_PRICING.image;
  return {provider: rate.provider, model, method: "multimodal_ai", pipelineVersion: "image-ai-v2", processingMs,
    inputTokens, outputTokens, totalTokens, audioDurationSeconds: null, billedAudioSeconds: null,
    estimatedCostUSD: model === rate.model && inputTokens !== null && outputTokens !== null ?
      inputTokens / 1e6 * rate.inputPricePerMillionTokens + outputTokens / 1e6 * rate.outputPricePerMillionTokens : null,
    pricingAsOf: RECOGNITION_PRICING.pricingAsOf, pricingVersion: RECOGNITION_PRICING.pricingVersion};
}
export function audioUsage(duration: number, billedSeconds: number, processingMs: number): RecognitionMetadata {
  const rate = RECOGNITION_PRICING.audio;
  return {provider: rate.provider, model: rate.model, method: "groq_asr", pipelineVersion: "audio-groq-v2", processingMs,
    inputTokens: null, outputTokens: null, totalTokens: null, audioDurationSeconds: duration, billedAudioSeconds: billedSeconds,
    estimatedCostUSD: billedSeconds / 3600 * rate.audioPricePerHour,
    pricingAsOf: RECOGNITION_PRICING.pricingAsOf, pricingVersion: RECOGNITION_PRICING.pricingVersion};
}

// Advertised before any new image upload; no legacy OCR route is supported.
export const IMAGE_PIPELINE = {provider: RECOGNITION_PRICING.image.provider, model: RECOGNITION_PRICING.image.model, method: "multimodal_ai", pipelineVersion: "image-ai-v2", fallback: false} as const;
