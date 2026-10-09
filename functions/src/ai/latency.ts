// Additive diagnostics. Unknown infrastructure cold-start/dispatch timings stay
// null; never present handler warmup as measured platform cold start.
export type Stage = "uploadMs" | "queueWaitMs" | "workerStartupMs" | "routerMs" |
  "nativeExtractionMs" | "ocrProbeMs" | "ocrMs" | "aiMs" | "persistenceMs" | "evidenceMs";
export interface VisualLatency {
  version: "visual-latency-v1";
  uploadTimingKind: "client-transfer" | "server-window" | null;
  uploadMs: number | null; queueWaitMs: number | null; workerStartupMs: number | null;
  routerMs: number; nativeExtractionMs: number; ocrProbeMs: number; ocrMs: number;
  aiMs: number; persistenceMs: number; evidenceMs: number | null; totalProcessingMs: number;
  coldStartMs: null; firstInvocation?: boolean;
  providerSpans: {stage: string; startedAt: number; finishedAt: number}[];
  providerCalls: number; providerBytes: number; renderCount: number; checkpointHits: number;
  pageCount: number; nativePageCount: number; ocrPageCount: number; aiPageCount: number;
  maxPageProcessingMs: number; pageProcessingMs: {pageNumber: number; processingMs: number}[];
}
export class LatencyMeter {
  readonly startedAt = Date.now();
  value: VisualLatency = {version: "visual-latency-v1", uploadMs: null, uploadTimingKind: null, queueWaitMs: null, workerStartupMs: null,
    routerMs: 0, nativeExtractionMs: 0, ocrProbeMs: 0, ocrMs: 0, aiMs: 0, persistenceMs: 0,
    evidenceMs: null, totalProcessingMs: 0, coldStartMs: null, providerSpans: [], providerCalls: 0, providerBytes: 0,
    renderCount: 0, checkpointHits: 0, pageCount: 0, nativePageCount: 0, ocrPageCount: 0, aiPageCount: 0,
    maxPageProcessingMs: 0, pageProcessingMs: []};
  async measure<T>(stage: Stage, fn: () => Promise<T>): Promise<T> {
    const start = performance.now(), wall = Date.now();
    try { return await fn(); } finally { this.add(stage, performance.now() - start);
      if (["ocrProbeMs", "ocrMs", "aiMs"].includes(stage) && this.value.providerSpans.length < 100) this.value.providerSpans.push({stage, startedAt: wall, finishedAt: Date.now()});
    }
  }
  add(stage: Stage, ms: number) { this.value[stage] = (this.value[stage] || 0) + Math.max(0, ms); }
  snapshot() { return {...this.value, totalProcessingMs: Date.now() - this.startedAt}; }
}
export const VISUAL_EXECUTION = Object.freeze({aiConcurrency: 2, ocrConcurrency: 3, pageConcurrency: 4,
  // Current production bound retained until real resize evidence justifies change.
  providerMaxSide: 1800, routerMaxSide: 640});
export function semaphore(limit: number) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 4) throw new Error("INVALID_VISUAL_CONCURRENCY");
  let active = 0; const waiting: (() => void)[] = [];
  return async <T>(fn: () => Promise<T>): Promise<T> => {
    if (active >= limit) await new Promise<void>(resolve => waiting.push(resolve));
    else active++;
    try { return await fn(); } finally { const next = waiting.shift(); if (next) next(); else active--; }
  };
}
// Drain active pages on first failure, stop launching new pages, then surface the
// original error. Completed checkpoints survive; no orphan provider work races a retry.
export async function boundedPages<T>(jobs: (() => Promise<T>)[], limit: number): Promise<T[]> {
  const values = new Array<T>(jobs.length); let cursor = 0, error: unknown;
  await Promise.all(Array.from({length: Math.min(limit, jobs.length)}, async () => {
    while (cursor < jobs.length && !error) {
      const i = cursor++;
      try { values[i] = await jobs[i](); } catch (e) { error ||= e; }
    }
  }));
  if (error) throw error;
  return values;
}

// Operator-only resize experiments use task data in Dev. The production worker
// always ignores this diagnostic input and keeps its reviewed 1800px bound.
export function devVisualOptions(project: string, data: any) {
  const side = data?.benchmarkProviderMaxSide;
  return project === "forta-aogaku-dev" && [4032, 2000, 1600, 1200].includes(side) ? {providerMaxSide: side} : {};
}
