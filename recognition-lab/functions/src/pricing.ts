// Recognition Lab only. Keep published rates/model mappings in this single table.
export type RecognitionPricing = {
  provider: string; model: string; pricingUnit: "million_tokens" | "audio_hour" | "thousand_images";
  inputPrice: number; outputPrice: number | null; currency: "USD"; pricingAsOf: string;
  minimumBillingSeconds?: number; freeMonthlyUnits?: number;
  volumeTiers?: Array<{fromUnit: number; pricePerThousand: number}>;
  sourceURL: string;
};
export const RECOGNITION_PRICING: RecognitionPricing[] = [
  {provider:"groq",model:"qwen/qwen3.8-27b",pricingUnit:"million_tokens",inputPrice:0.80,outputPrice:4.00,currency:"USD",pricingAsOf:"2026-10-08",sourceURL:"https://console.groq.com/docs/model/qwen/qwen3.8-27b"},
  {provider:"groq",model:"whisper-large-v3-turbo",pricingUnit:"audio_hour",inputPrice:0.04,outputPrice:null,currency:"USD",pricingAsOf:"2026-10-08",minimumBillingSeconds:10,sourceURL:"https://console.groq.com/docs/speech-to-text"},
  {provider:"google_cloud_vision",model:"DOCUMENT_TEXT_DETECTION",pricingUnit:"thousand_images",inputPrice:1.50,outputPrice:null,currency:"USD",pricingAsOf:"2026-10-08",freeMonthlyUnits:1000,volumeTiers:[{fromUnit:1001,pricePerThousand:1.50},{fromUnit:5000001,pricePerThousand:0.60}],sourceURL:"https://cloud.google.com/vision/pricing"}
];
export type TokenUsage = {promptTokens: number | null; completionTokens: number | null; totalTokens: number | null};
export type EstimatedCost = {
  pricing: RecognitionPricing | null; inputCostUSD: number | null; outputCostUSD: number | null;
  estimatedCostUSD: number | null; audioDurationSeconds?: number; billedAudioSeconds?: number;
  durationSource?: string; imageUnits?: number; notes: string[];
};
export function unavailableCost(provider: string, model: string): EstimatedCost {
  return {pricing:pricing(provider,model),inputCostUSD:null,outputCostUSD:null,estimatedCostUSD:null,notes:["Provider request failed or billing metadata unavailable. Possible charges are unknown, not zero."]};
}
function pricing(provider: string, model: string) {return RECOGNITION_PRICING.find(p=>p.provider===provider&&p.model===model)||null;}
function tokenCount(v: unknown): number | null {return typeof v==="number"&&Number.isSafeInteger(v)&&v>=0?v:null;}
export function measuredUsage(raw: any): TokenUsage {
  return {promptTokens:tokenCount(raw?.prompt_tokens),completionTokens:tokenCount(raw?.completion_tokens),totalTokens:tokenCount(raw?.total_tokens)};
}
export function estimateImage(model: string, usage: TokenUsage): EstimatedCost {
  const rate=pricing("groq",model);
  if(!rate||rate.pricingUnit!=="million_tokens")return {pricing:null,inputCostUSD:null,outputCostUSD:null,estimatedCostUSD:null,notes:["No pricing for returned model; cost unknown."]};
  const input=usage.promptTokens===null?null:usage.promptTokens/1000000*rate.inputPrice;
  const output=usage.completionTokens===null?null:usage.completionTokens/1000000*rate.outputPrice!;
  const notes=["API usage only; image tokenization is not calculated locally. Standard on-demand estimate, not an invoice."];
  if(input===null||output===null)notes.push("API usage missing/invalid; unknown cost is not zero.");
  return {pricing:rate,inputCostUSD:input,outputCostUSD:output,estimatedCostUSD:input===null||output===null?null:input+output,notes};
}
export function estimateAudio(model: string, measuredSeconds: number, providerSeconds?: unknown): EstimatedCost {
  const rate=pricing("groq",model);
  const fromAPI=typeof providerSeconds==="number"&&Number.isFinite(providerSeconds)&&providerSeconds>0;
  const seconds=fromAPI?providerSeconds as number:measuredSeconds;
  if(!rate||rate.pricingUnit!=="audio_hour"||!Number.isFinite(seconds)||seconds<=0)return {pricing:rate,inputCostUSD:null,outputCostUSD:null,estimatedCostUSD:null,notes:["Audio duration or model pricing unavailable."]};
  const billed=Math.max(rate.minimumBillingSeconds!,seconds),cost=billed/3600*rate.inputPrice;
  return {pricing:rate,inputCostUSD:cost,outputCostUSD:null,estimatedCostUSD:cost,audioDurationSeconds:seconds,billedAudioSeconds:billed,durationSource:fromAPI?"Groq response duration":"ffprobe measured file duration",notes:["Minimum billed length: 10 seconds per request. No undocumented additional rounding is assumed; billed duration is an estimate.","Audio-hour pricing, not token pricing. Not an invoice."]};
}
export function estimateOCR(): EstimatedCost {
  const rate=pricing("google_cloud_vision","DOCUMENT_TEXT_DETECTION")!;
  return {pricing:rate,inputCostUSD:rate.inputPrice/1000,outputCostUSD:null,estimatedCostUSD:rate.inputPrice/1000,imageUnits:1,notes:["Standard paid tier estimate for one image. Monthly usage is unknown: first 1,000 units free; units above 5,000,000 discounted. Free tier/volume discounts are not applied.","Actual OCR charge may be lower (including zero). Not an invoice; Functions/network costs excluded."]};
}
