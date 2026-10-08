import {EstimatedCost, TokenUsage, RECOGNITION_PRICING, unavailableCost} from "./pricing";
export const DEV_PROJECT = "forta-aogaku-dev";
// Official Groq vision documentation checked 2026-10-08. Account availability is checked per request.
export const IMAGE_MODEL = RECOGNITION_PRICING.find(p=>p.provider==="groq"&&p.pricingUnit==="million_tokens")!.model;
export const AUDIO_MODEL = RECOGNITION_PRICING.find(p=>p.provider==="groq"&&p.pricingUnit==="audio_hour")!.model;
export type ImageMode = "vision_ocr" | "vision_llm" | "vision_ocr_llm";
export type RecognitionResult = {rawText: string; normalizedText: string; structuredResult: string | null;
  method: string; provider: string; model: string; processingMs: number; warnings: string[]; error: string | null; usage?: TokenUsage; estimatedCost?: EstimatedCost};
export type ImageStructure = {sections: Array<{heading: string; printedText: string[]; handwrittenNotes: string[];
  relations: Array<{from: string; to: string; label: string; uncertain: boolean}>; tables: string[]; diagrams: string[]; summary: string}>; warnings: string[]};
export type Comparison = {method: string; results: RecognitionResult[]; ocrTextProvidedToAI: string | null;
  finalEvidenceText: string; warnings: string[]; totalProcessingMs?: number};
export class LabError extends Error { constructor(public code: string, public rawOutput?: string, public usage?: TokenUsage, public estimatedCost?: EstimatedCost) {super(code);} }
export function assertAccess(project: string | undefined, enabled: string, uid: string | undefined, allowed: string) {
  if (project !== DEV_PROJECT || enabled !== "true") throw new LabError("LAB_DEV_ONLY");
  if (!uid) throw new LabError("LAB_AUTH_REQUIRED");
  let values: unknown; try {values = JSON.parse(allowed);} catch {throw new LabError("LAB_CLOSED");}
  if (!Array.isArray(values) || !values.length || values.some(x => typeof x !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(x)) || !values.includes(uid)) throw new LabError("LAB_UID_DENIED");
}
export function payload(value: unknown, kind: "image" | "audio", mime: unknown): Buffer {
  const types = kind === "image" ? ["image/jpeg", "image/png"] : ["audio/mp4", "audio/m4a", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/mpeg"];
  if (!types.includes(String(mime)) || typeof value !== "string" || value.length > 4 * 1024 * 1024 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new LabError("LAB_INVALID_INPUT");
  const bytes = Buffer.from(value, "base64");
  if (!bytes.length || bytes.length > 3 * 1024 * 1024 || bytes.toString("base64") !== value) throw new LabError("LAB_SIZE_LIMIT");
  if (kind === "image" && !(mime === "image/png" ? bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])) : bytes[0] === 255 && bytes[1] === 216)) throw new LabError("LAB_INVALID_IMAGE");
  return bytes;
}
const text = (v: unknown) => {if (typeof v !== "string" || v.length > 12000) throw new LabError("LAB_INVALID_STRUCTURE"); return v;};
const texts = (v: unknown): string[] => {if (!Array.isArray(v) || v.length > 100) throw new LabError("LAB_INVALID_STRUCTURE"); return v.map(text);};
export function parseStructure(raw: string): ImageStructure {
  if (raw.length > 200000) throw new LabError("LAB_INVALID_STRUCTURE");
  let value: any; try {value = JSON.parse(raw);} catch {throw new LabError("LAB_INVALID_STRUCTURE");}
  if (!value || !Array.isArray(value.sections) || value.sections.length > 30) throw new LabError("LAB_INVALID_STRUCTURE");
  return {sections: value.sections.map((s: any) => {
    if (!s || !Array.isArray(s.relations) || s.relations.length > 100) throw new LabError("LAB_INVALID_STRUCTURE");
    return {heading: text(s.heading), printedText: texts(s.printedText), handwrittenNotes: texts(s.handwrittenNotes),
      relations: s.relations.map((r: any) => {if (!r || typeof r.uncertain !== "boolean") throw new LabError("LAB_INVALID_STRUCTURE"); return {from: text(r.from), to: text(r.to), label: text(r.label), uncertain: r.uncertain};}),
      tables: texts(s.tables), diagrams: texts(s.diagrams), summary: text(s.summary)};
  }), warnings: texts(value.warnings)};
}
export function evidence(s: ImageStructure): string {
  return s.sections.flatMap(x => [x.heading, ...x.printedText, ...x.handwrittenNotes.map(t=>`手書き注記: ${t}`),
    ...x.relations.map(r=>`${r.uncertain ? "不確実な関係: " : ""}${r.from} → ${r.to}${r.label ? `（${r.label}）` : ""}`), ...x.tables, ...x.diagrams, x.summary]).filter(Boolean).join("\n");
}
export interface ImageInterpreter {readonly provider: string; readonly model: string; interpret(bytes: Buffer, mime: string, ocr?: string): Promise<{raw: string; structure: ImageStructure; usage?: TokenUsage; estimatedCost?: EstimatedCost}>;}
export interface ImageOCR {recognize(bytes: Buffer): Promise<{text: string; structured: unknown; estimatedCost?: EstimatedCost}>;}
function failure(e: unknown) {return e instanceof LabError ? e.code : "LAB_PROVIDER_FAILED";}
export async function compareImage(mode: ImageMode, bytes: Buffer, mime: string, ocr: ImageOCR, ai: ImageInterpreter): Promise<Comparison> {
  if (!["vision_ocr", "vision_llm", "vision_ocr_llm"].includes(mode)) throw new LabError("LAB_INVALID_MODE");
  const comparisonStart=Date.now();
  const results: RecognitionResult[] = []; let ocrResult: RecognitionResult | undefined;
  if (mode !== "vision_llm") {
    const start = Date.now();
    try {const r=await ocr.recognize(bytes); ocrResult={rawText:r.text, normalizedText:r.text.trim(), structuredResult:JSON.stringify(r.structured), method:"vision_ocr",provider:"google_cloud_vision",model:"DOCUMENT_TEXT_DETECTION",processingMs:Date.now()-start,warnings:r.text.trim()?[]:["OCR_EMPTY"],error:null,estimatedCost:r.estimatedCost};}
    catch(e){ocrResult={rawText:"",normalizedText:"",structuredResult:null,method:"vision_ocr",provider:"google_cloud_vision",model:"DOCUMENT_TEXT_DETECTION",processingMs:Date.now()-start,warnings:[],error:failure(e),estimatedCost:e instanceof LabError?e.estimatedCost:undefined};}
    results.push(ocrResult);
  }
  const provided = mode === "vision_ocr_llm" && !ocrResult?.error ? ocrResult!.rawText : null;
  if (mode !== "vision_ocr") {
    const start = Date.now();
    try {const r=await ai.interpret(bytes,mime,provided ?? undefined);results.push({rawText:r.raw,normalizedText:evidence(r.structure),structuredResult:r.raw,method:mode,provider:ai.provider,model:ai.model,processingMs:Date.now()-start,warnings:r.structure.warnings,error:null,usage:r.usage,estimatedCost:r.estimatedCost});}
    catch(e){const raw=e instanceof LabError?e.rawOutput:undefined;results.push({rawText:raw||"",normalizedText:"",structuredResult:raw||null,method:mode,provider:ai.provider,model:ai.model,processingMs:Date.now()-start,warnings:raw?["RAW_STRUCTURE_INVALID_NOT_USED_AS_EVIDENCE"]:[],error:failure(e),usage:e instanceof LabError?e.usage:undefined,estimatedCost:(e instanceof LabError?e.estimatedCost:undefined)??unavailableCost(ai.provider,ai.model)});}
  }
  const selected = results.at(-1)!;
  const finalEvidenceText = selected.error ? ocrResult?.normalizedText || "" : selected.normalizedText;
  return {method:mode,results,ocrTextProvidedToAI:provided,finalEvidenceText,totalProcessingMs:Date.now()-comparisonStart,warnings:results.some(r=>r.error)?["PARTIAL_OR_FAILED_COMPARISON",...(selected.error && mode !== "vision_ocr" && finalEvidenceText ? ["FINAL_TEXT_IS_OCR_FALLBACK"] : [])]:[]};
}
