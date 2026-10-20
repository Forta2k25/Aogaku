import {InputError} from "./domain";
import {RECOGNITION_PRICING} from "./pricing";
import {geminiFetch, geminiUsage, logGeminiFailure, sameGeminiModel} from "./gemini";
import {chatUsage} from "./chat";

// ライブ録音: 録音しながら1分ごとの音声を文字にし、10分ごとの要約と、終わったあとのノートを作る。
// どれも「その場で結果を返す」処理で、資料(source)としては保存しない(保存は、録音が終わったあとにアプリが文字として送る)。

export const RECORDING = {
  segmentMaxSeconds: 75, segmentMinSeconds: 0.5, maxSegmentBytes: 3 * 1024 * 1024, maxSegmentIndex: 119,
  blockMaxChars: 9000, previousSummaryMaxChars: 1500, summaryMaxChars: 1500, noteInputMaxChars: 14000, maxSummaries: 20,
  minuteMax: 100, asrTimeoutMs: 60000, textTimeoutMs: 60000, maxOutputTokens: 1400,
  segmentsPerDay: 400, summariesPerDay: 60,
} as const;

export interface SegmentInput {recordingId: string; index: number; durationSeconds: number; audio: Buffer}
export interface TranscribedSegment {startMs: number; endMs: number; text: string; lowConfidence: boolean}

const RECORDING_ID = /^[A-Za-z0-9-]{8,64}$/;

/** 1分ほどの音声(m4a)の形式・大きさ・中身(先頭のバイト)を確かめる。 */
export function validateSegment(data: any): SegmentInput {
  const recordingId = data?.recordingId;
  if (typeof recordingId !== "string" || !RECORDING_ID.test(recordingId)) throw new InputError("INVALID_RECORDING");
  const index = data?.index;
  if (!Number.isInteger(index) || index < 0 || index > RECORDING.maxSegmentIndex) throw new InputError("INVALID_RECORDING");
  const durationSeconds = data?.durationSeconds;
  if (typeof durationSeconds !== "number" || !Number.isFinite(durationSeconds) ||
      durationSeconds < RECORDING.segmentMinSeconds || durationSeconds > RECORDING.segmentMaxSeconds) throw new InputError("INVALID_DURATION");
  const raw = data?.audio;
  if (typeof raw !== "string" || !raw || !/^[A-Za-z0-9+/]+={0,2}$/.test(raw)) throw new InputError("INVALID_AUDIO");
  const audio = Buffer.from(raw, "base64");
  // m4a(MP4)は、先頭から4バイト目に "ftyp" が来る。
  if (!audio.length || audio.length > RECORDING.maxSegmentBytes || audio.subarray(4, 8).toString("latin1") !== "ftyp") throw new InputError("INVALID_AUDIO");
  return {recordingId, index, durationSeconds, audio};
}

/** Groq の Whisper で、1分ほどの音声を文字にする。無音・確信の低い区間も、フラグで区別して返す。 */
export async function transcribeSegment(audio: Buffer, key: string, request: typeof fetch = fetch) {
  if (!key) throw new InputError("ASR_NOT_CONFIGURED");
  const form = new FormData();
  form.append("file", new Blob([new Uint8Array(audio)], {type: "audio/mp4"}), "audio.m4a");
  form.append("model", RECOGNITION_PRICING.audio.model); form.append("response_format", "verbose_json");
  form.append("language", "ja"); form.append("temperature", "0");
  let response: Response;
  try {
    response = await request("https://api.groq.com/openai/v1/audio/transcriptions", {method: "POST", headers: {Authorization: `Bearer ${key}`}, body: form, signal: AbortSignal.timeout(RECORDING.asrTimeoutMs)});
  } catch { throw new InputError("ASR_UNAVAILABLE", true); }
  if (!response.ok) throw new InputError("ASR_UNAVAILABLE", response.status === 429 || response.status >= 500);
  let result: any;
  try { result = await response.json(); } catch { throw new InputError("ASR_UNAVAILABLE", true); }
  if (!Array.isArray(result?.segments)) throw new InputError("ASR_MISSING_TIMESTAMPS", true);
  const segments: TranscribedSegment[] = [];
  for (const s of result.segments) {
    const text = String(s?.text ?? "").trim(), start = Number(s?.start), end = Number(s?.end);
    if (!text || !Number.isFinite(start) || !Number.isFinite(end) || Number(s?.no_speech_prob) > 0.8) continue;
    segments.push({startMs: Math.round(start * 1000), endMs: Math.round(end * 1000), text,
      lowConfidence: Number(s?.avg_logprob) < -1 || Number(s?.compression_ratio) > 2.4});
  }
  return {text: segments.map(s => s.text).join(""), segments};
}

// ---- 要約とノート(Gemini) ----

const BLOCK_SYSTEM = `あなたは、大学の講義の文字起こしを、学生のノートにまとめる助手です。文字起こしは、音声認識の結果なので、聞き間違い・誤変換・言い直しが混ざります。
守ること:
- 文字起こしに実際にある内容だけを書く。人名・数値・用語・式を、補ったり、推測で直したりしない。聞き取りが怪しい語は、聞こえたまま書く。
- 数字・用語・定義・例は、そのまま残す(要約で消さない)。
- 「文字起こしによると」などの前置きは書かない。
- 先生が「大事」「テストに出る」「覚えて」などと強調したときだけ、「先生が強調」に書く。無ければその項目は書かない。課題・連絡も同じ。
- 雑談や、授業と関係のない話は、省く。
形式(項目が無いときは、その行ごと書かない):
話題: (1行)
要点:
- (3〜6個。1個は1〜2文)
先生が強調: (あれば)
課題・連絡: (あれば)
全体で600字以内。`;
const NOTE_SYSTEM = `あなたは、大学の講義の、時間ごとの要約から、1回分のノートを作る助手です。
守ること:
- 与えられた要約に実際にある内容だけを書く。補ったり、推測で足したりしない。
- 数字・用語・定義は、そのまま残す。「要約によると」などの前置きは書かない。
- 項目が無いときは、その見出しごと書かない。
形式:
## この回のまとめ
(3〜5行)
## 流れ
- (時間帯: 話題。1行ずつ)
## 重要語
- 用語: 一言の説明(最大10個)
## 先生が強調したこと
- (あれば)
## 課題・連絡
- (あれば)
全体で1200字以内。`;

export interface BlockInput {text: string; startMinute: number; endMinute: number; previousSummary: string}
export interface NoteInput {summaries: Array<{startMinute: number; endMinute: number; text: string}>}

const clip = (v: unknown, max: number) => typeof v === "string" ? v.replace(/\u0000/g, "").trim().slice(0, max) : "";
const minute = (v: unknown) => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= RECORDING.minuteMax ? Math.floor(v) : null;

export function validateBlock(data: any): BlockInput {
  const text = clip(data?.text, RECORDING.blockMaxChars), start = minute(data?.startMinute), end = minute(data?.endMinute);
  if (!text || start === null || end === null || end < start) throw new InputError("INVALID_RECORDING");
  return {text, startMinute: start, endMinute: end, previousSummary: clip(data?.previousSummary, RECORDING.previousSummaryMaxChars)};
}
export function validateNote(data: any): NoteInput {
  const raw = data?.summaries;
  if (!Array.isArray(raw) || !raw.length || raw.length > RECORDING.maxSummaries) throw new InputError("INVALID_RECORDING");
  let total = 0;
  const summaries = raw.map((s: any) => {
    const text = clip(s?.text, RECORDING.summaryMaxChars), start = minute(s?.startMinute), end = minute(s?.endMinute);
    if (!text || start === null || end === null || end < start) throw new InputError("INVALID_RECORDING");
    total += text.length;
    return {startMinute: start, endMinute: end, text};
  });
  if (total > RECORDING.noteInputMaxChars) throw new InputError("INVALID_RECORDING");
  return {summaries};
}

export function blockPrompt(input: BlockInput) {
  const context = input.previousSummary ? `【直前までの要約(前後関係を知るためだけに使う。内容は繰り返さない)】\n${input.previousSummary}\n\n` : "";
  return `${context}【${input.startMinute}〜${input.endMinute}分の文字起こし】\n${input.text}`;
}
export function notePrompt(input: NoteInput) {
  return input.summaries.map(s => `【${s.startMinute}〜${s.endMinute}分】\n${s.text}`).join("\n\n");
}

/** Gemini に1回だけ頼んで、本文と実測の使用量を返す。 */
export async function generateText(key: string, system: string, user: string, request: typeof fetch = fetch) {
  if (!key) throw new InputError("CHAT_NOT_CONFIGURED");
  const model = RECOGNITION_PRICING.image.model, start = Date.now();
  let response: Response;
  try {
    response = await geminiFetch(request, key, model, "generateContent", {systemInstruction: {parts: [{text: system}]},
      contents: [{role: "user", parts: [{text: user}]}], generationConfig: {temperature: 0.2, maxOutputTokens: RECORDING.maxOutputTokens}}, RECORDING.textTimeoutMs);
  } catch { throw new InputError("CHAT_UNAVAILABLE", true); }
  if (!response.ok) { await logGeminiFailure("recording", response); throw new InputError(response.status === 429 ? "CHAT_RATE_LIMIT" : "CHAT_UNAVAILABLE", true); }
  let result: any;
  try { result = await response.json(); } catch { throw new InputError("CHAT_INVALID_RESULT", true); }
  if (!sameGeminiModel(result.modelVersion, model)) throw new InputError("CHAT_MODEL_MISMATCH", true);
  const candidate = result.candidates?.[0];
  // 途中で止まった文章を、完成したものとして返さない。
  if (candidate?.finishReason !== "STOP") throw new InputError("CHAT_INVALID_RESULT");
  const text = (candidate?.content?.parts || []).filter((p: any) => !p.thought).map((p: any) => p.text ?? "").join("").trim();
  if (!text || text.length > 6000) throw new InputError("CHAT_INVALID_RESULT", true);
  return {text, recognition: chatUsage(geminiUsage(result.usageMetadata), model, Date.now() - start)};
}
export const summarizeBlock = (key: string, input: BlockInput, request: typeof fetch = fetch) => generateText(key, BLOCK_SYSTEM, blockPrompt(input), request);
export const makeNote = (key: string, input: NoteInput, request: typeof fetch = fetch) => generateText(key, NOTE_SYSTEM, notePrompt(input), request);
