import {InputError} from "./domain";
import {RECOGNITION_PRICING} from "./pricing";
import {geminiFetch, geminiUsage, logGeminiFailure, sameGeminiModel} from "./gemini";
import {chatUsage} from "./chat";

// 質問(と写真)が、どの授業のものかを、授業の一覧から予想する。授業時間の付近は、アプリが時間割で決めるので、ここは、時間外のとき用。

export const ROUTING = {
  maxCourses: 12, maxIdChars: 64, maxNameChars: 80, maxTeacherChars: 40, maxHintChars: 500, maxQuestionChars: 600,
  maxImageBytes: 700 * 1024, maxOutputTokens: 500, timeoutMs: 30000, maxCandidates: 3, minConfidence: 0.15,
} as const;

export interface RouteCourse {id: string; name: string; teacher: string; hint: string}
export interface RouteInput {question: string; courses: RouteCourse[]; image?: {mime: "image/jpeg"; data: string}}
export interface RouteCandidate {id: string; confidence: number; reason: string}

const clip = (v: unknown, max: number) => typeof v === "string" ? v.replace(/\u0000/g, "").trim().slice(0, max) : "";

export function validateRoute(data: any): RouteInput {
  const question = clip(data?.question, ROUTING.maxQuestionChars);
  const rawCourses = data?.courses;
  if (!Array.isArray(rawCourses) || !rawCourses.length || rawCourses.length > ROUTING.maxCourses) throw new InputError("INVALID_ROUTE");
  const seen = new Set<string>();
  const courses = rawCourses.map((c: any) => {
    const id = clip(c?.id, ROUTING.maxIdChars), name = clip(c?.name, ROUTING.maxNameChars);
    if (!id || !name || seen.has(id)) throw new InputError("INVALID_ROUTE");
    seen.add(id);
    return {id, name, teacher: clip(c?.teacher, ROUTING.maxTeacherChars), hint: clip(c?.hint, ROUTING.maxHintChars)};
  });
  let image: RouteInput["image"];
  if (data?.image !== undefined && data?.image !== null) {
    const raw = data.image?.data;
    if (data.image?.mime !== "image/jpeg" || typeof raw !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(raw)) throw new InputError("INVALID_ROUTE");
    const bytes = Buffer.from(raw, "base64");
    if (!bytes.length || bytes.length > ROUTING.maxImageBytes || bytes[0] !== 255 || bytes[1] !== 216) throw new InputError("INVALID_ROUTE");
    image = {mime: "image/jpeg", data: raw};
  }
  if (!question && !image) throw new InputError("INVALID_ROUTE");
  return {question, courses, image};
}

const SYSTEM = `あなたは、大学生の質問(と、添えられた写真)が、どの授業のものかを当てる助手です。
授業の一覧(ID・名前・先生・授業の内容や最近の話題のヒント)が与えられます。質問・写真の内容に、いちばん近い授業を、近い順に、最大3つ選んでください。
守ること:
- 根拠にするのは、質問・写真の中身(用語・科目名・先生の名前・資料の話題・言語)と、授業のヒントだけ。授業の順番や、時間帯は、根拠にしない。
- 自信(0〜1)は、正直につける。どの授業とも関係が薄いとき、複数の授業に同じくらい当てはまるときは、無理に1つに決めず、自信を低くするか、候補を出さない(空の一覧)。
- 与えられた一覧に無いIDを、作らない。
- 理由(reason)は、20文字以内の日本語で、何が決め手かだけを書く。
JSON だけを返す。`;

export const ROUTE_SCHEMA = {type: "OBJECT", required: ["ranked"], properties: {ranked: {type: "ARRAY", items: {type: "OBJECT",
  required: ["id", "confidence", "reason"], properties: {id: {type: "STRING"}, confidence: {type: "NUMBER"}, reason: {type: "STRING"}}}}}};

export function routePrompt(input: RouteInput) {
  const list = input.courses.map(c => `- ID: ${c.id}\n  名前: ${c.name}${c.teacher ? `\n  先生: ${c.teacher}` : ""}${c.hint ? `\n  ヒント: ${c.hint}` : ""}`).join("\n");
  return `【授業の一覧】\n${list}\n\n【質問】\n${input.question || "(文字なし。添えられた写真だけ)"}`;
}

/** Gemini の返事を、検証して、近い順の候補にする。一覧に無いID・範囲外の自信・重複は、捨てる。 */
export function parseRanked(raw: string, input: RouteInput): RouteCandidate[] {
  let parsed: any;
  try { parsed = JSON.parse(raw); } catch { throw new InputError("ROUTE_INVALID_RESULT", true); }
  if (!Array.isArray(parsed?.ranked)) throw new InputError("ROUTE_INVALID_RESULT", true);
  const ids = new Set(input.courses.map(c => c.id)), seen = new Set<string>(), out: RouteCandidate[] = [];
  for (const r of parsed.ranked) {
    const id = typeof r?.id === "string" ? r.id : "", confidence = Number(r?.confidence);
    if (!ids.has(id) || seen.has(id) || !Number.isFinite(confidence)) continue;
    seen.add(id);
    out.push({id, confidence: Math.max(0, Math.min(1, confidence)), reason: clip(r?.reason, 40)});
  }
  return out.filter(c => c.confidence >= ROUTING.minConfidence).sort((a, b) => b.confidence - a.confidence).slice(0, ROUTING.maxCandidates);
}

export async function routeCourse(key: string, input: RouteInput, request: typeof fetch = fetch) {
  if (!key) throw new InputError("CHAT_NOT_CONFIGURED");
  const model = RECOGNITION_PRICING.image.model, start = Date.now();
  const parts: Record<string, unknown>[] = [{text: routePrompt(input)}];
  if (input.image) parts.unshift({inline_data: {mime_type: input.image.mime, data: input.image.data}});
  let response: Response;
  try {
    response = await geminiFetch(request, key, model, "generateContent", {systemInstruction: {parts: [{text: SYSTEM}]},
      contents: [{role: "user", parts}], generationConfig: {temperature: 0, maxOutputTokens: ROUTING.maxOutputTokens, responseMimeType: "application/json", responseSchema: ROUTE_SCHEMA}}, ROUTING.timeoutMs);
  } catch { throw new InputError("CHAT_UNAVAILABLE", true); }
  if (!response.ok) { await logGeminiFailure("route", response); throw new InputError(response.status === 429 ? "CHAT_RATE_LIMIT" : "CHAT_UNAVAILABLE", true); }
  let result: any;
  try { result = await response.json(); } catch { throw new InputError("CHAT_INVALID_RESULT", true); }
  if (!sameGeminiModel(result.modelVersion, model)) throw new InputError("CHAT_MODEL_MISMATCH", true);
  const candidate = result.candidates?.[0];
  if (candidate?.finishReason !== "STOP") throw new InputError("ROUTE_INVALID_RESULT", true);
  const raw = (candidate?.content?.parts || []).filter((p: any) => !p.thought).map((p: any) => p.text ?? "").join("").trim();
  return {ranked: parseRanked(raw, input), recognition: chatUsage(geminiUsage(result.usageMetadata), model, Date.now() - start)};
}
