import {ImageAnnotatorClient} from "@google-cloud/vision";
import {execFile} from "node:child_process";
import {promisify} from "node:util";
import {readFile, mkdtemp, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join, dirname} from "node:path";
import {Extraction, InputError, Unit} from "./domain";

const exec = promisify(execFile);
type Checkpoint = {load: (key: string) => Promise<any | undefined>; save: (key: string, value: any) => Promise<void>; alive: () => Promise<void>};
let visionClient: ImageAnnotatorClient | undefined;
const vision = () => visionClient ||= new ImageAnnotatorClient();
const importModule = new Function("name", "return import(name)") as (name: string) => Promise<any>;

async function cached(cp: Checkpoint, key: string, fn: () => Promise<any>) {
  await cp.alive();
  const old = await cp.load(key);
  if (old) return old;
  const result = await fn();
  await cp.save(key, result);
  return result;
}
export async function extractImage(path: string, cp: Checkpoint): Promise<Extraction> {
  const result = await cached(cp, "image", async () => {
    const [response] = await vision().documentTextDetection({image: {content: await readFile(path)}});
    if (response.error?.code) throw new InputError("OCR_UNAVAILABLE", true);
    return {text: response.fullTextAnnotation?.text || "", annotation: response.fullTextAnnotation || {}};
  });
  if (!result.text.trim()) throw new InputError("SOURCE_UNREADABLE");
  return {units: [{text: result.text, locator: {imageIndex: 1}, method: "vision_ocr", flags: []}], totalUnits: 1, failedUnits: [], raw: result};
}
export async function extractPDF(path: string, gsURI: string, cp: Checkpoint): Promise<Extraction> {
  const pdfjs = await importModule("pdfjs-dist/legacy/build/pdf.mjs");
  const assets = dirname(require.resolve("pdfjs-dist/package.json"));
  const task = pdfjs.getDocument({data: new Uint8Array(await readFile(path)), isEvalSupported: false,
    cMapUrl: join(assets, "cmaps") + "/", cMapPacked: true, standardFontDataUrl: join(assets, "standard_fonts") + "/"});
  try {
    let doc: any;
    try { doc = await task.promise; }
    catch (e: any) { throw new InputError(e.name === "PasswordException" ? "ENCRYPTED_PDF" : "INVALID_PDF"); }
    if (doc.numPages > 50) throw new InputError("TOO_MANY_PAGES");
    const units: Unit[] = [], failedUnits: number[] = [];
    for (let page = 1; page <= doc.numPages; page++) {
      try {
        const result = await cached(cp, `pdf6-cmaps-page-${page}`, async () => {
          const p = await doc.getPage(page);
          const content = await p.getTextContent();
          let text = content.items.map((x: any) => x.str || "").join(" ").trim();
          let method = "pdf_text";
          if (text.length < 20) {
            const [r] = await vision().batchAnnotateFiles({requests: [{
              inputConfig: {gcsSource: {uri: gsURI}, mimeType: "application/pdf"},
              features: [{type: "DOCUMENT_TEXT_DETECTION"}], pages: [page]
            }]});
            const file = r.responses?.[0];
            const image = file?.responses?.[0];
            if (file?.error?.code || image?.error?.code) throw new InputError("OCR_UNAVAILABLE", true);
            text = image?.fullTextAnnotation?.text || ""; method = "vision_ocr";
          }
          return {text, method};
        });
        if (!result.text.trim()) { failedUnits.push(page); continue; }
        units.push({text: result.text, method: result.method, locator: {pageNumber: page}, flags: ["figures_not_interpreted"]});
      } catch (e) {
        if (e instanceof InputError && e.code === "CANCELLED") throw e;
        failedUnits.push(page);
      }
    }
    if (!units.length) throw new InputError("PDF_EXTRACTION_FAILED", true);
    return {units, totalUnits: doc.numPages, failedUnits};
  } finally { await task.destroy(); }
}
export async function audioDuration(path: string): Promise<number> {
  const probe = require("ffprobe-static").path;
  const {stdout} = await exec(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", path], {timeout: 30000});
  const value = Number(stdout.trim());
  if (!Number.isFinite(value) || value < 1 || value > 5400) throw new InputError("INVALID_DURATION");
  return value;
}
async function groq(path: string, key: string, model: string) {
  if (!key) throw new InputError("ASR_NOT_CONFIGURED");
  const form = new FormData();
  const buffer = await readFile(path);
  form.append("file", new Blob([new Uint8Array(buffer)], {type: "audio/mp4"}), "audio.m4a");
  form.append("model", model); form.append("response_format", "verbose_json");
  form.append("language", "ja"); form.append("temperature", "0");
  const r = await fetch("https://api.groq.com/openai/v1/audio/transcriptions", {method: "POST", headers: {Authorization: `Bearer ${key}`}, body: form, signal: AbortSignal.timeout(180000)});
  if (!r.ok) throw new InputError("ASR_UNAVAILABLE", r.status === 429 || r.status >= 500);
  return await r.json() as any;
}
export function mergeSegments(parts: Array<{offset: number; coreStart: number; result: any}>, duration: number): Unit[] {
  const units: Unit[] = [];
  for (const part of parts) {
    const segments = part.result.segments;
    if (!Array.isArray(segments)) throw new InputError("ASR_MISSING_TIMESTAMPS", true);
    for (const s of segments) {
      const start = part.offset + Number(s.start), end = Math.min(duration, part.offset + Number(s.end));
      // Discard only segments entirely contained in the overlap, then trim exact repeated text.
      if (!Number.isFinite(start) || !Number.isFinite(end) || end <= part.coreStart || end <= start) continue;
      let text = String(s.text || "").trim();
      const previous = units.at(-1);
      if (previous && start * 1000 < (previous.locator.endMs || 0)) {
        if (previous.text.endsWith(text)) continue;
        for (let size = Math.min(previous.text.length, text.length); size >= 4; size--) {
          if (previous.text.endsWith(text.slice(0, size))) { text = text.slice(size); break; }
        }
      }
      if (!text || Number(s.no_speech_prob) > .8) continue;
      const flags = [];
      if (Number(s.avg_logprob) < -1 || Number(s.compression_ratio) > 2.4) flags.push("low_confidence");
      if (start < part.coreStart) flags.push("overlap_boundary");
      units.push({text, locator: {startMs: Math.round(start * 1000), endMs: Math.round(end * 1000)}, method: "groq_asr", flags});
    }
  }
  return units;
}
export async function extractAudio(path: string, duration: number, key: string, cp: Checkpoint): Promise<Extraction> {
  const directory = await mkdtemp(join(tmpdir(), "ai-audio-"));
  const parts: Array<{offset: number; coreStart: number; result: any}> = [], failedUnits: number[] = [];
  try {
    for (let coreStart = 0, index = 0; coreStart < duration; coreStart += 900, index++) {
      const offset = Math.max(0, coreStart - 2);
      try {
        const result = await cached(cp, `audio-${index}`, async () => {
          const out = join(directory, `${index}.m4a`);
          await exec(require("ffmpeg-static"), ["-nostdin", "-y", "-ss", String(offset), "-i", path, "-t", String(Math.min(900 + coreStart - offset, duration - offset)), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "48k", out], {timeout: 120000, maxBuffer: 1024 ** 2});
          const first = await groq(out, key, "whisper-large-v3-turbo");
          const bad = (first.segments || []).some((s: any) => s.avg_logprob < -1 || s.compression_ratio > 2.4);
          if (!bad) return {...first, selectedModel: "whisper-large-v3-turbo"};
          try { return {...await groq(out, key, "whisper-large-v3"), firstPass: first, selectedModel: "whisper-large-v3"}; }
          catch { return {...first, selectedModel: "whisper-large-v3-turbo", retryFailed: true}; }
        });
        parts.push({offset, coreStart, result});
      } catch (e) {
        if (e instanceof InputError && ["CANCELLED", "ASR_NOT_CONFIGURED"].includes(e.code)) throw e;
        failedUnits.push(index + 1);
      }
    }
    const units = mergeSegments(parts, duration);
    if (!units.length) throw new InputError(failedUnits.length ? "ASR_UNAVAILABLE" : "SOURCE_UNREADABLE", failedUnits.length > 0);
    return {units, totalUnits: Math.ceil(duration / 900), failedUnits, raw: parts};
  } finally { await rm(directory, {recursive: true, force: true}); }
}
