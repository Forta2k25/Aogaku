import {InputError} from "./domain";

// Gemini Developer API (generateContent). Shared by image recognition and chat.
export const GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta";
export const GEMINI_RETRY = {delaysMs: [1500, 3500]};

/** Map Gemini usageMetadata onto the {prompt,completion,total} shape the pricing helpers read. Thinking tokens are billed as output. */
export function geminiUsage(meta: any) {
  const n = (v: unknown) => typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null;
  const prompt = n(meta?.promptTokenCount), candidates = n(meta?.candidatesTokenCount), thoughts = n(meta?.thoughtsTokenCount) ?? 0;
  return {prompt_tokens: prompt, completion_tokens: candidates === null ? null : candidates + thoughts, total_tokens: n(meta?.totalTokenCount)};
}
/** modelVersion may carry a suffix; accept only the pinned model family. */
export function sameGeminiModel(version: unknown, model: string) {
  return typeof version === "string" && version.replace(/^models\//, "").startsWith(model);
}
/** POST with a short retry on overload (503) / rate limit (429), so a brief spike does not fail the user's request. */
export async function geminiFetch(request: typeof fetch, key: string, model: string, method: "generateContent" | "streamGenerateContent",
  body: unknown, timeoutMs: number): Promise<Response> {
  const url = `${GEMINI_ENDPOINT}/models/${model}:${method}${method === "streamGenerateContent" ? "?alt=sse" : ""}`;
  for (let attempt = 0; ; attempt++) {
    const response = await request(url, {method: "POST", headers: {"x-goog-api-key": key, "Content-Type": "application/json"},
      signal: AbortSignal.timeout(timeoutMs), body: JSON.stringify(body)});
    if (response.ok || ![429, 503].includes(response.status) || attempt >= GEMINI_RETRY.delaysMs.length) return response;
    await new Promise(resolve => setTimeout(resolve, GEMINI_RETRY.delaysMs[attempt]));
  }
}
export function requireKey(key: string, code: string) { if (!key) throw new InputError(code); }
/** Log the provider's own error status/message (never the key or the payload) so an outage is diagnosable from server logs. */
export async function logGeminiFailure(context: string, response: Response) {
  let detail = "";
  try { detail = String(((await response.clone().json()) as any)?.error?.message ?? "").slice(0, 300); } catch { /* body is optional */ }
  console.error(`${context}: Gemini HTTP ${response.status} ${detail}`);
}
