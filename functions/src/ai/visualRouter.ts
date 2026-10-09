import {InputError, Extraction, Unit} from "./domain";
import {RecognitionMetadata, RECOGNITION_PRICING} from "./pricing";

export type VisualRoute = "native_text" | "vision_ocr" | "multimodal_ai";
export type Box = {x: number; y: number; w: number; h: number};
export interface VisualFeatures {
  nativeTextLength: number; nativeTextQuality: number; textCoverage: number;
  textBlockCount: number; imageCoverage: number; drawingCount: number;
  drawingScore: number; blockDispersion: number; readingOrderPenalty: number;
  nonTextCoverage: number; lineScore: number; relationMark: boolean;
  ocrCharacterCount: number; ocrQuality: number; probeAvailable: boolean;
  // Image-only geometry signal; absent for PDF and historical routing metadata.
  connectorComponents?: number;
}
export interface RoutingDecision {
  route: VisualRoute; routingScore: number; routingReason: string[];
  nativeTextQuality: number; ocrQuality: number; visualComplexity: number;
  features: VisualFeatures;
}
export interface RoutedPage extends RoutingDecision {
  pageNumber?: number; imageIndex?: number; provider: string; model: string | null;
  inputTokens: number | null; outputTokens: number | null; totalTokens: number | null;
  aiCostUSD: number | null; ocrCostUSD: number; estimatedCostUSD: number | null;
  ocrUnits: number; processingMs: number;
}
export interface RoutingSummary {
  routerVersion: string; pages: RoutedPage[];
  counts: Record<VisualRoute, number>; ocrUnits: number;
  aiCostUSD: number | null; ocrCostUSD: number; pricingAssumption: string;
}
export const VISUAL_ROUTER = Object.freeze({version: "visual-router-v1", low: .30, high: .55,
  nativeQuality: .78, ocrQuality: .78, minimumCharacters: 30,
  weights: {image: .10, dispersion: .15, drawing: .20, order: .15, nonText: .20, lines: .20}});
export const AUTO_CAPABILITIES = {
  image: {pipelineVersion: "image-auto-v1", method: "auto_route", routes: ["vision_ocr", "multimodal_ai"],
    provider: "groq", model: RECOGNITION_PRICING.image.model, fallback: false, routerVersion: VISUAL_ROUTER.version},
  pdf: {pipelineVersion: "pdf-auto-v1", method: "auto_route", routes: ["native_text", "vision_ocr", "multimodal_ai"],
    provider: "groq", model: RECOGNITION_PRICING.image.model, fallback: false, routerVersion: VISUAL_ROUTER.version}
};
export const clamp = (v: number) => Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 1;
export const emptyFeatures = (): VisualFeatures => ({nativeTextLength: 0, nativeTextQuality: 0, textCoverage: 0,
  textBlockCount: 0, imageCoverage: 0, drawingCount: 0, drawingScore: 0, blockDispersion: 0,
  readingOrderPenalty: 0, nonTextCoverage: 0, lineScore: 0, relationMark: false,
  ocrCharacterCount: 0, ocrQuality: 0, probeAvailable: false});

export function chooseVisualRoute(kind: "pdf" | "image", f: VisualFeatures): RoutingDecision {
  const w = VISUAL_ROUTER.weights;
  // A full-page scanned text bitmap is not itself proof of a semantic illustration.
  const semanticImage = f.nativeTextLength > 0 ? f.imageCoverage : f.imageCoverage * f.nonTextCoverage;
  let score = clamp(semanticImage * w.image + f.blockDispersion * w.dispersion + f.drawingScore * w.drawing +
    f.readingOrderPenalty * w.order + f.nonTextCoverage * w.nonText + f.lineScore * w.lines);
  const reasons: string[] = [];
  if (kind === "image" && (f.connectorComponents ?? 0) > 0) {
    score = Math.max(score, .60); reasons.push("raster_connectors_between_text");
  }
  if (f.relationMark) { score = Math.max(score, .85); reasons.push("explicit_relation_marks"); }
  if (f.lineScore >= .5) { score = Math.max(score, .60); reasons.push("connectors_or_grid"); }
  if (f.drawingScore >= .5) { score = Math.max(score, .60); reasons.push("semantic_vector_drawing"); }
  if ((f.nativeTextLength || f.imageCoverage < .8) && f.imageCoverage >= .12) { score = Math.max(score, .55); reasons.push("embedded_visual_content"); }
  if (f.nonTextCoverage >= .35) { score = Math.max(score, .55); reasons.push("non_text_visual_content"); }
  if (f.blockDispersion >= .6) reasons.push("distributed_text_blocks");
  if (f.readingOrderPenalty >= .3) reasons.push("irregular_reading_order");
  let route: VisualRoute = "multimodal_ai";
  if (score < VISUAL_ROUTER.low && kind === "pdf" && f.nativeTextQuality >= VISUAL_ROUTER.nativeQuality) {
    route = "native_text"; reasons.push("embedded_text_available", "low_visual_complexity");
  } else if (score < VISUAL_ROUTER.low && f.probeAvailable && f.ocrQuality >= VISUAL_ROUTER.ocrQuality) {
    route = "vision_ocr"; reasons.push("high_ocr_quality", "simple_text_layout");
  } else {
    if (score >= VISUAL_ROUTER.high) reasons.push("high_visual_complexity");
    else if (score >= VISUAL_ROUTER.low) reasons.push("ambiguous_visual_complexity");
    else reasons.push(f.probeAvailable ? "insufficient_text_quality" : "probe_unavailable");
  }
  return {route, routingScore: score, routingReason: [...new Set(reasons)], nativeTextQuality: f.nativeTextQuality,
    ocrQuality: f.ocrQuality, visualComplexity: score, features: f};
}

export function textQuality(text: string) {
  const value = text.replace(/\s/g, ""), bad = (value.match(/[\uFFFD\x00-\x08]/g) || []).length;
  return clamp(Math.min(1, value.length / VISUAL_ROUTER.minimumCharacters) * (1 - bad / Math.max(1, value.length)));
}
export function layoutFeatures(boxes: Box[]) {
  if (!boxes.length) return {coverage: 0, dispersion: 0, order: 0};
  const coverage = clamp(boxes.reduce((sum, b) => sum + Math.max(0, b.w) * Math.max(0, b.h), 0));
  const starts = boxes.map(b => Math.round(b.x * 10));
  const aligned = Math.max(...[...new Set(starts)].map(x => starts.filter(v => v === x).length)) / starts.length;
  let backward = 0;
  for (let i = 1; i < boxes.length; i++) {
    if (boxes[i].y < boxes[i - 1].y - Math.max(.025, boxes[i].h * 2)) backward++;
  }
  return {coverage, dispersion: clamp((1 - aligned) * .6), order: clamp(backward / Math.max(1, boxes.length - 1) * 4)};
}

export function rasterFeatures(data: Uint8ClampedArray, width: number, height: number, words: Box[]) {
  const mask = new Uint8Array(width * height), outside = new Uint8Array(width * height);
  for (const b of words) {
    const x0 = Math.max(0, Math.floor((b.x - .003) * width)), y0 = Math.max(0, Math.floor((b.y - .003) * height));
    const x1 = Math.min(width, Math.ceil((b.x + b.w + .003) * width)), y1 = Math.min(height, Math.ceil((b.y + b.h + .003) * height));
    for (let y = y0; y < y1; y++) mask.fill(1, y * width + x0, y * width + x1);
  }
  let ink = 0, other = 0;
  for (let i = 0; i < mask.length; i++) {
    const o = i * 4, dark = data[o + 3] > 80 && (.2126 * data[o] + .7152 * data[o + 1] + .0722 * data[o + 2]) < 205;
    if (dark) { ink++; if (!mask[i]) { other++; outside[i] = 1; } }
  }
  // Long strokes outside word boxes reveal arrows, table grids, frames and chart axes.
  let lines = 0;
  function scan(indices: number[], minimum: number) {
    let run = 0, gaps = 0, found = false;
    for (const i of indices) {
      if (outside[i]) { run++; gaps = 0; } else if (run && gaps++ < 1) { run++; } else { run = 0; gaps = 0; }
      if (run >= minimum && !found) { lines++; found = true; }
    }
  }
  const min = Math.max(25, Math.round(Math.min(width, height) * .065));
  for (let y = 0; y < height; y += 2) scan(Array.from({length: width}, (_, x) => y * width + x), min);
  for (let x = 0; x < width; x += 2) scan(Array.from({length: height}, (_, y) => y * width + x), min);
  for (let start = -height; start < width; start += 3) {
    for (const direction of [1, -1]) {
      const indices = []; for (let y = 0; y < height; y++) { const x = start + direction * y; if (x >= 0 && x < width) indices.push(y * width + x); }
      scan(indices, min);
    }
  }
  return {nonTextCoverage: clamp(other / Math.max(1, ink)), lineScore: clamp(lines / 4)};
}

/** Short raster connectors can disappear from OCR, and fall below long-stroke
 * detection. Inspect only unrecognized ink between separated word boxes. This
 * does not identify the relation or generate Evidence; it only routes to AI.
 * The image analysis canvas is bounded to 640 pixels by the caller. */
export function imageConnectorFeatures(data: Uint8ClampedArray, width: number, height: number, words: Box[]) {
  const ink = new Uint8Array(width * height), seen = new Uint8Array(ink.length);
  for (let i = 0; i < ink.length; i++) {
    const o = i * 4;
    ink[i] = Number(data[o + 3] > 80 && (.2126 * data[o] + .7152 * data[o + 1] + .0722 * data[o + 2]) < 205);
  }
  // Use the same padding as rasterFeatures, avoiding glyphs/punctuation within
  // OCR words while retaining arrows omitted entirely by the OCR service.
  for (const b of words) {
    const x0 = Math.max(0, Math.floor((b.x - .003) * width)), y0 = Math.max(0, Math.floor((b.y - .003) * height));
    const x1 = Math.min(width, Math.ceil((b.x + b.w + .003) * width)), y1 = Math.min(height, Math.ceil((b.y + b.h + .003) * height));
    for (let y = y0; y < y1; y++) ink.fill(0, y * width + x0, y * width + x1);
  }
  const queue = new Int32Array(ink.length);
  const minimum = Math.max(8, Math.round(Math.min(width, height) * .018));
  let connectorComponents = 0;
  for (let start = 0; start < ink.length; start++) {
    if (!ink[start] || seen[start]) continue;
    let head = 0, tail = 1, x0 = width, x1 = 0, y0 = height, y1 = 0;
    queue[0] = start; seen[start] = 1;
    while (head < tail) {
      const at = queue[head++], x = at % width, y = Math.floor(at / width);
      x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y);
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const xx = x + dx, yy = y + dy;
        if (xx < 0 || xx >= width || yy < 0 || yy >= height) continue;
        const next = yy * width + xx;
        if (ink[next] && !seen[next]) { seen[next] = 1; queue[tail++] = next; }
      }
    }
    const w = x1 - x0 + 1, h = y1 - y0 + 1;
    // Skip specks and filled glyph-like components. A thin or arrow-shaped
    // component must also occupy a blank gap between two real text regions.
    if (Math.max(w, h) < minimum || tail < 6 || tail / (w * h) > .70 || Math.max(w, h) / Math.min(w, h) < 1.5) continue;
    const cx = (x0 + x1) / (2 * width), cy = (y0 + y1) / (2 * height);
    const vertical = h >= w;
    const near = words.filter(b => vertical ? cx >= b.x - .03 && cx <= b.x + b.w + .03 : cy >= b.y - .025 && cy <= b.y + b.h + .025);
    const before = near.some(b => vertical ? b.y + b.h < y0 / height && y0 / height - b.y - b.h < .22 : b.x + b.w < x0 / width && x0 / width - b.x - b.w < .30);
    const after = near.some(b => vertical ? b.y > (y1 + 1) / height && b.y - (y1 + 1) / height < .22 : b.x > (x1 + 1) / width && b.x - (x1 + 1) / width < .30);
    if (before && after) connectorComponents++;
  }
  return {connectorComponents};
}

export function routedPage(decision: RoutingDecision, locator: {pageNumber?: number; imageIndex?: number}, ms: number,
  ocrUnits: number, ai?: RecognitionMetadata): RoutedPage {
  const native = decision.route === "native_text", multimodal = decision.route === "multimodal_ai";
  const aiCost = multimodal ? ai?.estimatedCostUSD ?? null : 0;
  const ocrCost = ocrUnits * RECOGNITION_PRICING.ocr.pricePerThousand / 1000;
  return {...decision, ...locator, provider: native ? "pdfjs" : multimodal ? "groq" : "google_vision",
    model: native ? null : multimodal ? RECOGNITION_PRICING.image.model : "DOCUMENT_TEXT_DETECTION",
    inputTokens: multimodal ? ai?.inputTokens ?? null : 0, outputTokens: multimodal ? ai?.outputTokens ?? null : 0,
    totalTokens: multimodal ? ai?.totalTokens ?? null : 0, aiCostUSD: aiCost, ocrCostUSD: ocrCost,
    estimatedCostUSD: aiCost === null ? null : aiCost + ocrCost, ocrUnits, processingMs: ms};
}
export function aggregateRouting(pages: RoutedPage[], kind: "pdf" | "image", ms: number): RecognitionMetadata {
  const counts = {native_text: 0, vision_ocr: 0, multimodal_ai: 0};
  pages.forEach(p => counts[p.route]++);
  const total = (key: "inputTokens" | "outputTokens" | "totalTokens" | "aiCostUSD") =>
    pages.some(p => p[key] === null) ? null : pages.reduce((s, p) => s + (p[key] as number), 0);
  const aiCostUSD = total("aiCostUSD"), ocrCostUSD = pages.reduce((s, p) => s + p.ocrCostUSD, 0);
  return {provider: counts.multimodal_ai ? (counts.native_text || counts.vision_ocr ? "mixed" : "groq") : counts.vision_ocr ? "google_vision" : "pdfjs",
    model: counts.multimodal_ai ? RECOGNITION_PRICING.image.model : counts.vision_ocr ? "DOCUMENT_TEXT_DETECTION" : "native_text",
    method: "auto_route", pipelineVersion: kind === "pdf" ? "pdf-auto-v1" : "image-auto-v1", processingMs: ms,
    inputTokens: total("inputTokens"), outputTokens: total("outputTokens"), totalTokens: total("totalTokens"),
    audioDurationSeconds: null, billedAudioSeconds: null, estimatedCostUSD: aiCostUSD === null ? null : aiCostUSD + ocrCostUSD,
    pricingAsOf: RECOGNITION_PRICING.ocr.pricingAsOf, pricingVersion: "visual-router-pricing-v1",
    routing: {routerVersion: VISUAL_ROUTER.version, pages, counts, ocrUnits: pages.reduce((s, p) => s + p.ocrUnits, 0),
      aiCostUSD, ocrCostUSD, pricingAssumption: "Vision standard paid tier; monthly free/volume tiers and infrastructure/retry costs not included"}};
}
export function assertAutoExtraction(value: Extraction, kind: "pdf" | "image") {
  const r = value.recognition, expected = kind === "pdf" ? "pdf-auto-v1" : "image-auto-v1";
  if (r?.pipelineVersion !== expected || r.method !== "auto_route" || r.routing?.routerVersion !== VISUAL_ROUTER.version || !r.routing?.pages.length || !value.units.length ||
      r.routing.pages.some(p => !["native_text", "vision_ocr", "multimodal_ai"].includes(p.route)) ||
      r.routing.pages.some(p => p.route === "multimodal_ai" && (p.provider !== "groq" || p.model !== RECOGNITION_PRICING.image.model)) ||
      value.units.some(u => !r.routing!.pages.some(p => u.method === p.route &&
        (kind === "pdf" ? u.locator.pageNumber === p.pageNumber : u.locator.imageIndex === p.imageIndex)))) {
    throw new InputError("VISUAL_ROUTER_CONTRACT_MISMATCH", true);
  }
}
