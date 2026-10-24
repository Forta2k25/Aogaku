import {chunksFor, InputError, mayPublish} from "./domain";
import {aggregateRouting} from "./visualRouter";
import {PageResult} from "./visualExtraction";
// Preview is a separate run namespace. It is never an activeRun, never a RAG
// chunk collection, and is guarded by the current source lease/version.
export function previewAllowed(source: any, uid: string) {
  return source?.ownerUserId === uid && source.sourceType === "pdf" && source.pipelineVersion === "pdf-auto-v1" &&
    ["extracting", "indexing"].includes(source.status) && typeof source.previewRun === "string" && source.previewRun.length > 0 && source.previewRun === source.leaseToken;
}
export async function publishPreviewBatch(database: any, ref: any, owner: any, token: string, results: PageResult[], total: number, admission: () => boolean) {
  const pages = results.map(result => {
    const number = result.unit.locator.pageNumber;
    if (!number || !Number.isInteger(number) || number < 1 || number > total) throw new InputError("INVALID_PAGE");
    return {result, number, ref: ref.collection("runs").doc(token).collection("previewPages").doc(String(number).padStart(4, "0"))};
  });
  await database.runTransaction(async (tx: any) => {
    const [s, o, ...previous] = await Promise.all([tx.get(ref), tx.get(owner), ...pages.map(p => tx.get(p.ref))]);
    const source = s.data();
    if (!admission() || ["deleting", "deleted"].includes(o.get("state")) || !mayPublish(source, token) || source.previewRun !== token) throw new InputError("CANCELLED");
    const progress = {...(source.previewProgress || {completed: 0, native: 0, ocr: 0, ai: 0}), total};
    for (const [index, page] of pages.entries()) {
      if (previous[index].exists) continue;
      const key = page.result.unit.method === "native_text" ? "native" : page.result.unit.method === "vision_ocr" ? "ocr" : "ai";
      const chunks = chunksFor([page.result.unit]).map(c => ({...c, chunkId: String(page.number).padStart(4, "0") + "-" + c.chunkId, unitIndex: page.number - 1}));
      tx.set(page.ref, {pageNumber: page.number, page: page.result.page, chunks});
      progress.completed++; progress[key]++;
    }
    tx.update(ref, {previewProgress: progress});
  });
}
export function previewPublisher(database: any, ref: any, owner: any, token: string, admission: () => boolean) {
  let pending: PageResult[] = [], total = 0, chain = Promise.resolve();
  const flush = () => {
    const batch = pending; pending = [];
    if (batch.length) chain = chain.then(() => publishPreviewBatch(database, ref, owner, token, batch, total, admission));
    return chain;
  };
  return {
    pageReady: (result: PageResult, count: number) => {
      total = count; pending.push(result);
      // First useful native page immediately; subsequent native pages in groups
      // of five. Provider pages publish as soon as complete. All flush before ready.
      return result.unit.locator.pageNumber === 1 || result.unit.method !== "native_text" || pending.length >= 5 ? flush() : Promise.resolve();
    },
    flushPreview: flush
  };
}

export function previewResponse(source: any, pages: any[]) {
  const recognition = aggregateRouting(pages.map(p => p.page), "pdf", 0);
  return {items: pages.flatMap(p => p.chunks.map((c: any) => ({...c, sourceId: source.sourceId, lectureId: source.lectureId}))),
    recognition, status: source.status, pipelineVersion: source.pipelineVersion,
    preview: true, previewVersion: source.previewRun, progress: source.previewProgress, activeVersion: null};
}
