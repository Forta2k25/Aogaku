import {readFile} from "node:fs/promises";
import {dirname, join} from "node:path";
import {ImageAnnotatorClient} from "@google-cloud/vision";
import {createCanvas, loadImage} from "@napi-rs/canvas";
import {Extraction, InputError, Unit} from "./domain";
import {GroqImageRecognition, ImageRecognitionProvider, assertImageExtraction} from "./recognition";
import {Box, VisualFeatures, emptyFeatures, clamp, textQuality, layoutFeatures, rasterFeatures,
  chooseVisualRoute, routedPage, aggregateRouting, assertAutoExtraction, imageConnectorFeatures} from "./visualRouter";

type Checkpoint = {alive: () => Promise<void>; load: (key: string) => Promise<any>;
  save: (key: string, value: any) => Promise<void>; reserveProviderCall?: () => Promise<void>};
export interface OCRProbe {text: string; words: Box[]; confidence: number; blocks: Box[]}
export interface RouterProviders {ocr: (bytes: Buffer) => Promise<OCRProbe>; ai: ImageRecognitionProvider}
const importModule = new Function("name", "return import(name)") as (name: string) => Promise<any>;
let vision: ImageAnnotatorClient | undefined;
export function compactOCR(response: any): OCRProbe {
  const full = response.fullTextAnnotation, words: Box[] = [], blocks: Box[] = [];
  let confidence = 0, characters = 0;
  const box = (vertices: any[], width: number, height: number): Box => {
    const xs = vertices.map(p => Number(p.x) || 0), ys = vertices.map(p => Number(p.y) || 0);
    return {x: clamp(Math.min(...xs) / width), y: clamp(Math.min(...ys) / height),
      w: clamp((Math.max(...xs) - Math.min(...xs)) / width), h: clamp((Math.max(...ys) - Math.min(...ys)) / height)};
  };
  for (const page of full?.pages || []) {
    const width = Math.max(1, page.width || 1), height = Math.max(1, page.height || 1);
    for (const block of page.blocks || []) {
      if (block.boundingBox?.vertices?.length) blocks.push(box(block.boundingBox.vertices, width, height));
      for (const paragraph of block.paragraphs || []) for (const word of paragraph.words || []) {
        if (word.boundingBox?.vertices?.length) words.push(box(word.boundingBox.vertices, width, height));
        const length = (word.symbols || []).length;
        const quality = word.confidence ?? paragraph.confidence ?? block.confidence ?? page.confidence ?? 0;
        confidence += Math.max(0, Math.min(1, quality)) * length; characters += length;
      }
    }
  }
  return {text: String(full?.text || "").slice(0, 80000), words: words.slice(0, 12000),
    blocks: blocks.slice(0, 2000), confidence: characters ? confidence / characters : 0};
}
export function routerProviders(key: string): RouterProviders {
  return {ai: new GroqImageRecognition(key), ocr: async bytes => {
    const [result] = await (vision ||= new ImageAnnotatorClient()).documentTextDetection({image: {content: bytes}});
    if (result.error?.code) throw new InputError("OCR_UNAVAILABLE", true);
    return compactOCR(result);
  }};
}
async function cache<T>(cp: Checkpoint, key: string, fn: () => Promise<T>): Promise<T> {
  await cp.alive(); const old = await cp.load(key); if (old) return old;
  const value = await fn(); await cp.alive(); await cp.save(key, value); return value;
}
async function raster(bytes: Buffer, words: Box[], imageOnly = false) {
  const image = await loadImage(bytes);
  if (!image.width || !image.height || image.width * image.height > 40_000_000) throw new InputError("IMAGE_DIMENSION_LIMIT");
  const scale = Math.min(1, 640 / Math.max(image.width, image.height)), w = Math.max(1, Math.round(image.width * scale)), h = Math.max(1, Math.round(image.height * scale));
  const canvas = createCanvas(w, h), ctx = canvas.getContext("2d"); ctx.fillStyle = "white"; ctx.fillRect(0, 0, w, h); ctx.drawImage(image, 0, 0, w, h);
  const data = ctx.getImageData(0, 0, w, h).data;
  return {...rasterFeatures(data, w, h, words), ...(imageOnly ? imageConnectorFeatures(data, w, h, words) : {})};
}
async function probeFeatures(bytes: Buffer, cp: Checkpoint, providers: RouterProviders, name: string, original: VisualFeatures, kind: "pdf" | "image") {
  // Compact, reusable checkpoint, never raw Vision responses / annotations in Firestore.
  const probe = await cache(cp, name + "-ocr-probe", async () => {
    await cp.reserveProviderCall?.(); return providers.ocr(bytes);
  });
  const layout = layoutFeatures(probe.blocks), pixels = await raster(bytes, probe.words, kind === "image");
  return {probe, features: {...original, ...pixels, textCoverage: layout.coverage, textBlockCount: probe.blocks.length,
    blockDispersion: layout.dispersion, readingOrderPenalty: layout.order,
    relationMark: original.relationMark || /[→←↑↓↔⇒⇐⇔↗↘]/.test(probe.text),
    ocrCharacterCount: probe.text.replace(/\s/g, "").length,
    ocrQuality: clamp(probe.confidence * textQuality(probe.text)), probeAvailable: true}};
}
async function pageResult(bytes: Buffer | undefined, nativeText: string, features: VisualFeatures,
  locator: {pageNumber?: number; imageIndex?: number}, cp: Checkpoint, providers: RouterProviders, name: string, kind: "pdf" | "image") {
  const started = Date.now(); let decision = chooseVisualRoute(kind, features), ocrUnits = 0, ocrText = "";
  // Native/simple pages and structurally obvious visuals need no OCR round trip.
  if (decision.route !== "native_text" && decision.visualComplexity < .55) {
    if (!bytes) throw new InputError("MISSING_PAGE_RENDER", true);
    const probe = await probeFeatures(bytes, cp, providers, name, features, kind);
    ocrUnits = 1; ocrText = probe.probe.text; decision = chooseVisualRoute(kind, probe.features);
  }
  let text: string, ai: Extraction | undefined;
  if (decision.route === "native_text") text = nativeText;
  else if (decision.route === "vision_ocr") text = ocrText;
  else {
    if (!bytes) throw new InputError("MISSING_PAGE_RENDER", true);
    await cp.alive(); await cp.reserveProviderCall?.();
    // No catch-and-OCR fallback. A selected AI page fails/retries as AI.
    ai = await providers.ai.recognize(bytes, "image/png");
    assertImageExtraction(ai);
    text = ai.units.map(u => u.text).join("\n");
  }
  if (!text.trim()) throw new InputError("SOURCE_UNREADABLE", true);
  const unit: Unit = {text: text.trim(), method: decision.route, locator, flags: []};
  return {unit, page: routedPage(decision, locator, Date.now() - started, ocrUnits, ai?.recognition)};
}
export async function extractAutoImage(path: string, key: string, cp: Checkpoint, providers = routerProviders(key)): Promise<Extraction> {
  const started = Date.now();
  const result = await cache(cp, "image-auto-v1-final", async () => {
    const raw = await readFile(path), image = await loadImage(raw);
    if (image.width * image.height > 40_000_000) throw new InputError("IMAGE_DIMENSION_LIMIT");
    // Canonical PNG probe/AI input; preserve full readable layout while bounding model resolution.
    const scale = Math.min(1, 1800 / Math.max(image.width, image.height));
    const canvas = createCanvas(Math.max(1, Math.round(image.width * scale)), Math.max(1, Math.round(image.height * scale)));
    const ctx = canvas.getContext("2d"); ctx.fillStyle = "white"; ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
    return pageResult(canvas.toBuffer("image/png"), "", emptyFeatures(), {imageIndex: 1}, cp, providers, "image-auto-v1", "image");
  });
  const value = {units: [result.unit], totalUnits: 1, failedUnits: [], recognition: aggregateRouting([result.page], "image", Date.now() - started)};
  assertAutoExtraction(value, "image"); return value;
}

const multiply = (a: number[], b: number[]) => [a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1],
  a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3], a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5]];
export async function analyzePDFPage(page: any, OPS: any): Promise<{text: string; features: VisualFeatures}> {
  const viewport = page.getViewport({scale: 1}), content = await page.getTextContent(), operators = await page.getOperatorList();
  if (operators.fnArray.length > 200000 || content.items.length > 30000) throw new InputError("PDF_ANALYSIS_LIMIT");
  const items = content.items.filter((x: any) => typeof x.str === "string" && x.str.trim());
  const text = items.map((x: any) => x.str + (x.hasEOL ? "\n" : " ")).join("").trim();
  const boxes: Box[] = items.map((x: any) => {
    const [left, baseline] = viewport.convertToViewportPoint(x.transform[4], x.transform[5]);
    return {x: clamp(left/viewport.width), y: clamp((baseline-x.height)/viewport.height), w: clamp(x.width/viewport.width), h: clamp(x.height/viewport.height)};
  });
  const layout = layoutFeatures(boxes), stack: number[][] = [];
  let matrix = [1,0,0,1,0,0], imageCoverage = 0, drawingCount = 0;
  const images = [OPS.paintImageXObject, OPS.paintInlineImageXObject, OPS.paintImageMaskXObject, OPS.paintImageXObjectRepeat];
  for (let i = 0; i < operators.fnArray.length; i++) {
    const op = operators.fnArray[i];
    if (op === OPS.save) stack.push([...matrix]);
    else if (op === OPS.restore) matrix = stack.pop() || [1,0,0,1,0,0];
    else if (op === OPS.transform) matrix = multiply(matrix, operators.argsArray[i]);
    else if (images.includes(op)) imageCoverage += Math.abs(matrix[0]*matrix[3]-matrix[1]*matrix[2]) / (viewport.width*viewport.height);
    else if (op === OPS.constructPath || op === OPS.shadingFill) drawingCount++;
  }
  let features = {...emptyFeatures(), nativeTextLength: text.replace(/\s/g, "").length, nativeTextQuality: textQuality(text),
    textCoverage: layout.coverage, textBlockCount: items.length, imageCoverage: clamp(imageCoverage), drawingCount,
    drawingScore: clamp(Math.max(0, drawingCount - 2) / 8), blockDispersion: layout.dispersion, readingOrderPenalty: layout.order,
    relationMark: /[→←↑↓↔⇒⇐⇔↗↘]/.test(text)};
  // Even a single vector path can contain an arrow or table. Inspect its pixels
  // before declaring embedded text sufficient; this local render makes no API call.
  if (drawingCount && features.nativeTextQuality >= .78) {
    const pixels = await raster(await renderRouterPage(page), boxes);
    // PDF producers also draw backgrounds and glyph paths. Count only paths with
    // visible ink outside text boxes, rather than treating operator count as meaning.
    features = {...features, ...pixels, drawingScore: features.drawingScore * pixels.nonTextCoverage};
  }
  return {text, features};
}
export async function openRouterPDF(path: string) {
  const pdfjs = await importModule("pdfjs-dist/legacy/build/pdf.mjs"), assets = dirname(require.resolve("pdfjs-dist/package.json"));
  const task = pdfjs.getDocument({data: new Uint8Array(await readFile(path)), isEvalSupported: false, maxImageSize: 16_000_000,
    cMapUrl: join(assets, "cmaps") + "/", cMapPacked: true, standardFontDataUrl: join(assets, "standard_fonts") + "/"});
  let doc;
  try { doc = await task.promise; } catch (e: any) { await task.destroy(); throw new InputError(e.name === "PasswordException" ? "ENCRYPTED_PDF" : "INVALID_PDF"); }
  if (doc.numPages > 50) { await task.destroy(); throw new InputError("TOO_MANY_PAGES"); }
  return {doc, OPS: pdfjs.OPS, destroy: () => task.destroy()};
}
export async function renderRouterPage(page: any) {
  const base = page.getViewport({scale: 1}), viewport = page.getViewport({scale: Math.min(2.5, 1800/Math.max(base.width, base.height))});
  const canvas = createCanvas(Math.ceil(viewport.width), Math.ceil(viewport.height));
  const render = page.render({canvas, canvasContext: canvas.getContext("2d"), viewport});
  const timer = setTimeout(() => render.cancel(), 90000);
  try { await render.promise; return canvas.toBuffer("image/png"); }
  catch { throw new InputError("PDF_RENDER_UNAVAILABLE", true); } finally { clearTimeout(timer); canvas.width=1; canvas.height=1; }
}
export async function extractAutoPDF(path: string, key: string, cp: Checkpoint, providers = routerProviders(key)): Promise<Extraction> {
  const started = Date.now(), pdf = await openRouterPDF(path), units: Unit[] = [], pages = [];
  try {
    for (let number = 1; number <= pdf.doc.numPages; number++) {
      const result = await cache(cp, `pdf-auto-v1-page-${number}`, async () => {
        const p = await pdf.doc.getPage(number), analysis = await analyzePDFPage(p, pdf.OPS);
        const route = chooseVisualRoute("pdf", analysis.features);
        const bytes = route.route === "native_text" ? undefined : await renderRouterPage(p);
        const result = await pageResult(bytes, analysis.text, analysis.features, {pageNumber: number}, cp, providers, `pdf-auto-v1-page-${number}`, "pdf");
        p.cleanup(); return result;
      });
      units.push(result.unit); pages.push(result.page);
    }
    const value = {units, totalUnits: pdf.doc.numPages, failedUnits: [], recognition: aggregateRouting(pages, "pdf", Date.now()-started)};
    assertAutoExtraction(value, "pdf"); return value;
  } finally { await pdf.destroy(); }
}
