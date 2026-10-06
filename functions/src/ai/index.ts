import * as admin from "firebase-admin";
import {onCall, HttpsError} from "firebase-functions/v2/https";
import {onTaskDispatched} from "firebase-functions/v2/tasks";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {onObjectFinalized} from "firebase-functions/v2/storage";
import {defineString} from "firebase-functions/params";
import {getFunctions} from "firebase-admin/functions";
import {randomUUID, createHash} from "node:crypto";
import {mkdtemp, rm, readFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {PIPELINE, InputError, validateCreate, id, str, integer, hash, canRead, mayPublish, chunksFor, weekKey, selectContext, Extraction} from "./domain";
import {extractAudio, extractImage, extractPDF, audioDuration} from "./extractors";

const region = "asia-northeast1";
const runtimeAccount = defineString("AI_RUNTIME_SERVICE_ACCOUNT");
const db = () => admin.firestore();
const bucket = () => admin.storage().bucket();
const sources = () => db().collection("aiSources");
const now = () => Date.now();
const terminal = ["ready", "partial_ready", "failed", "deleting", "deleted"];
const queue = () => getFunctions().taskQueue(`locations/${region}/functions/aiProcessSource`);
function callable(fn: (uid: string, data: any) => Promise<any>) {
  return onCall({region, serviceAccount: runtimeAccount, timeoutSeconds: 120, maxInstances: 10}, async request => {
    if (!request.auth) throw new HttpsError("unauthenticated", "ログインしてください");
    try { if (!request.data || typeof request.data !== "object") throw new InputError("INVALID_REQUEST");
      return await fn(request.auth.uid, request.data); }
    catch (e) {
      if (e instanceof HttpsError) throw e;
      if (e instanceof InputError) throw new HttpsError(e.code === "NOT_FOUND" ? "not-found" : e.code === "FORBIDDEN" ? "permission-denied" : "failed-precondition", e.code, {code: e.code, retryable: e.retryable});
      console.error("AI input failure", e instanceof Error ? e.name : "unknown");
      throw new HttpsError("internal", "処理に失敗しました。再試行してください", {code: "INTERNAL", retryable: true});
    }
  });
}
async function verified(uid: string, courseId: string) {
  const s = await db().doc(`aiCourseOfferings/${courseId}/memberships/${uid}`).get();
  return s.get("status") === "verified" && s.get("active") === true;
}
async function owned(uid: string, sourceId: unknown) {
  const ref = sources().doc(id(sourceId)); const snap = await ref.get();
  if (!snap.exists) throw new InputError("NOT_FOUND");
  const source = snap.data()!;
  if (source.ownerUserId !== uid) throw new InputError("FORBIDDEN");
  return {ref, source};
}
function publicSource(s: any) {
  const {sourceId, sourceType, title, courseOfferingId, lectureId, dayID, status, error, coverage, rawVisibility, knowledgeVisibility, createdAt, activeRun, sourceVersion} = s;
  return {sourceId, sourceType, title, courseOfferingId, lectureId, dayID, status, error: error || null,
    coverage: coverage || null, rawVisibility, knowledgeVisibility, createdAt, sourceVersion, activeVersion: activeRun || null};
}
function runtimeProject() {
  const project = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || admin.app().options.projectId;
  if (!project || !/^[a-z][a-z0-9-]+$/.test(project)) throw new InputError("RUNTIME_NOT_CONFIGURED");
  return project;
}
async function adcRequest(url: string) {
  const credential = admin.app().options.credential;
  if (!credential) throw new InputError("RUNTIME_NOT_CONFIGURED");
  const token = await credential.getAccessToken();
  return fetch(url, {headers: {Authorization: `Bearer ${token.access_token}`}, signal: AbortSignal.timeout(30000)});
}
let workerUri: string | undefined;
async function taskTarget() {
  if (!workerUri) {
    const name = `projects/${runtimeProject()}/locations/${region}/functions/aiProcessSource`;
    const response = await adcRequest(`https://cloudfunctions.googleapis.com/v2/${name}`);
    if (!response.ok) throw new InputError("TASK_TARGET_UNAVAILABLE", true);
    const metadata = await response.json() as any;
    const uri = metadata.serviceConfig?.uri;
    if (metadata.name !== name || typeof uri !== "string" || !/^https:\/\/[^/]+\.a\.run\.app\/?$/.test(uri)) throw new InputError("TASK_TARGET_INVALID");
    workerUri = uri;
  }
  return workerUri;
}
async function groqSecret() {
  // ADC + secret-scoped IAM. No key is needed for image/PDF/note processing.
  const response = await adcRequest(`https://secretmanager.googleapis.com/v1/projects/${runtimeProject()}/secrets/GROQ_API_KEY/versions/latest:access`);
  if (response.status === 404) throw new InputError("ASR_NOT_CONFIGURED");
  if (!response.ok) throw new InputError("ASR_SECRET_UNAVAILABLE", response.status === 429 || response.status >= 500);
  const payload = await response.json() as any;
  const key = Buffer.from(payload.payload?.data || "", "base64").toString("utf8").trim();
  if (!key) throw new InputError("ASR_NOT_CONFIGURED");
  return key;
}
async function enqueue(sourceId: string) {
  await queue().enqueue({sourceId}, {dispatchDeadlineSeconds: 1800, uri: await taskTarget()});
  await sources().doc(sourceId).update({lastEnqueuedAt: now()});
}
async function uploadInfo(source: any) {
  if (source.sourceType === "note" || source.status !== "awaiting_upload") return null;
  const [url] = await bucket().file(source.storagePath).getSignedUrl({version: "v4", action: "write", expires: now() + 10 * 60 * 1000,
    contentType: source.mime, extensionHeaders: {"x-goog-if-generation-match": "0"}});
  return {url, headers: {"Content-Type": source.mime, "x-goog-if-generation-match": "0"}};
}

async function resolveContext(uid: string, context: ReturnType<typeof validateCreate>["context"]) {
  const c = context;
  if (c.classDocId?.includes("/")) throw new InputError("INVALID_CLASS");
  const classExists = c.classDocId ? (await db().collection("classes").doc(c.classDocId).get()).exists : false;
  if (c.classDocId && !classExists) throw new InputError("CLASS_NOT_FOUND");
  const courseOfferingId = hash(classExists ? c.classDocId : [uid, c.localCourseId], c.year, c.semester);
  return {courseOfferingId, lectureId: hash(courseOfferingId, c.dayID, c.occurrenceKey)};

}

export const aiCreateSource = callable(async (uid, data) => {
  const input = validateCreate(data);
  const c = input.context;
  const {courseOfferingId, lectureId} = await resolveContext(uid, c);
  const sourceId = hash(uid, input.clientRequestId);
  const ref = sources().doc(sourceId), fingerprint = hash(input);
  const day = new Date(now() + 9 * 3600000).toISOString().slice(0, 10);
  const usageRef = db().doc(`aiUsage/${uid}/periods/day-${day}`);
  const audioRef = db().doc(`aiUsage/${uid}/periods/week-${weekKey(new Date())}`);
  const source = await db().runTransaction(async tx => {
    const existing = await tx.get(ref);
    if (existing.exists) {
      if (existing.get("fingerprint") !== fingerprint) throw new InputError("REQUEST_CONFLICT");
      if (["deleted", "deleting"].includes(existing.get("status"))) throw new InputError("SOURCE_DELETED");
      return existing.data()!;
    }
    const [daily, weekly] = await Promise.all([tx.get(usageRef), tx.get(audioRef)]);
    const bytes = daily.get("bytes") || 0, count = daily.get("count") || 0, seconds = weekly.get("seconds") || 0;
    const reservation = input.durationSeconds || 0;
    if (count >= 100 || bytes + input.size > 500 * 1024 ** 2 || seconds + reservation > 10800) throw new InputError("QUOTA_EXCEEDED");
    const source = {sourceId, sourceVersion: 1, schemaVersion: 1, pipelineVersion: PIPELINE,
      fingerprint, ownerUserId: uid, courseOfferingId, lectureId, dayID: c.dayID,
      sourceType: input.type, title: input.title, mime: input.mime, declaredSize: input.size,
      declaredDuration: reservation, audioUsagePath: audioRef.path,
      rawVisibility: "private", knowledgeVisibility: "private", status: input.type === "note" ? "queued" : "awaiting_upload",
      storagePath: `ai-inputs/${uid}/${sourceId}/${input.type === "audio" ? "audio/original.m4a" : "original"}`, createdAt: now(), updatedAt: now(), attempts: 0,
      ...(input.text ? {noteText: input.text} : {})};
    tx.set(ref, source);
    tx.set(usageRef, {bytes: bytes + input.size, count: count + 1});
    if (reservation) tx.set(audioRef, {seconds: seconds + reservation});
    tx.set(db().doc(`aiCourseOfferings/${courseOfferingId}`), {year: c.year, semester: c.semester, classDocId: c.classDocId || null}, {merge: true});
    tx.set(db().doc(`aiCourseOfferings/${courseOfferingId}/lectures/${lectureId}`), {dayID: c.dayID, occurrenceKey: c.occurrenceKey}, {merge: true});
    return source;
  });
  if (source.status === "queued") await enqueue(sourceId);
  return {...publicSource(source), upload: await uploadInfo(source)};
});

export const aiCompleteSource = callable(async (uid, data) => {
  const {ref, source} = await owned(uid, data.sourceId);
  if (source.status === "awaiting_upload") {
    let metadata: any;
    try { [metadata] = await bucket().file(source.storagePath).getMetadata(); }
    catch { throw new InputError("UPLOAD_INCOMPLETE", true); }
    if (Number(metadata.size) !== source.declaredSize || metadata.contentType !== source.mime) throw new InputError("UPLOAD_MISMATCH");
    await db().runTransaction(async tx => {
      const latest = await tx.get(ref);
      if (latest.get("status") === "awaiting_upload") tx.update(ref, {status: "queued", objectGeneration: metadata.generation, updatedAt: now()});
    });
  }
  const latest = (await ref.get()).data()!;
  if (latest.status === "queued") await enqueue(ref.id);
  return publicSource(latest);
});
export const aiGetSource = callable(async (uid, data) => {
  const {source} = await owned(uid, data.sourceId);
  return publicSource(source);
});
export const aiListSources = callable(async (uid, data) => {
  const resolved = data.context ? await resolveContext(uid, validateCreate({clientRequestId: "resolve", type: "note", title: "resolve", mime: "text/plain", text: "resolve", context: data.context}).context) : null;
  const course = resolved?.courseOfferingId || id(data.courseOfferingId);
  const lecture = data.lectureId || (data.onlyLecture ? resolved?.lectureId : undefined);
  const after = data.after ? id(data.after) : undefined;
  let query = sources().where("courseOfferingId", "==", course).orderBy(admin.firestore.FieldPath.documentId()).limit(101);
  if (after) query = query.startAfter(after);
  const [snap, member] = await Promise.all([query.get(), verified(uid, course)]);
  const page = snap.docs.slice(0, 100);
  return {items: page.map(d => d.data()).filter(s => canRead(s, uid, member) && (!lecture || s.lectureId === lecture)).map(publicSource),
    courseOfferingId: course, lectureId: resolved?.lectureId || null, nextCursor: snap.size > 100 ? page.at(-1)!.id : null};
});
export const aiGetEvidence = callable(async (uid, data) => {
  const ref = sources().doc(id(data.sourceId)), source = (await ref.get()).data();
  if (!source || !canRead(source, uid, await verified(uid, source.courseOfferingId))) throw new InputError("NOT_FOUND");
  if (!source.activeRun) return {items: [], status: source.status, nextCursor: null};
  let q = ref.collection("runs").doc(source.activeRun).collection("chunks").orderBy("chunkId").limit(21);
  if (data.after) q = q.startAfter(id(data.after));
  const chunks = await q.get();
  const latest = (await ref.get()).data();
  if (!latest || latest.activeRun !== source.activeRun || !canRead(latest, uid, await verified(uid, source.courseOfferingId))) throw new InputError("NOT_FOUND");
  return {items: chunks.docs.slice(0, 20).map(d => ({...d.data(), sourceId: ref.id, lectureId: latest.lectureId})),
    status: latest.status, coverage: latest.coverage || null, nextCursor: chunks.size > 20 ? chunks.docs[19].id : null};
});

export const aiRetrySource = callable(async (uid, data) => {
  const {ref} = await owned(uid, data.sourceId);
  await db().runTransaction(async tx => {
    const s = (await tx.get(ref)).data()!;
    if (!["failed", "partial_ready"].includes(s.status)) return;
    if (s.attempts >= 6 || now() - s.createdAt >= 24 * 3600000) throw new InputError("RETRY_LIMIT");
    tx.update(ref, {status: "queued", error: null, updatedAt: now()});
  });
  if ((await ref.get()).get("status") === "queued") await enqueue(ref.id);
  return publicSource((await ref.get()).data());
});
export const aiUpdateSource = callable(async (uid, data) => {
  const {ref, source} = await owned(uid, data.sourceId);
  const changes: any = {updatedAt: now()};
  if (data.title !== undefined) changes.title = str(data.title, "TITLE");
  for (const key of ["rawVisibility", "knowledgeVisibility"]) {
    if (data[key] === undefined) continue;
    if (!["private", "course"].includes(data[key])) throw new InputError("INVALID_VISIBILITY");
    if (data[key] === "course" && !(await verified(uid, source.courseOfferingId))) throw new InputError("MEMBERSHIP_NOT_VERIFIED");
    changes[key] = data[key];
  }
  await db().runTransaction(async tx => {
    const s = (await tx.get(ref)).data()!;
    if (["deleting", "deleted"].includes(s.status)) throw new InputError("SOURCE_DELETED");
    tx.update(ref, changes);
  });
  return publicSource((await ref.get()).data());
});

async function purge(ref: admin.firestore.DocumentReference) {
  const source = (await ref.get()).data();
  if (!source || !["deleting", "deleted"].includes(source.status)) return;
  for (const prefix of [`ai-inputs/${source.ownerUserId}/${ref.id}/`, `ai-derived/${source.ownerUserId}/${ref.id}/`]) {
    await bucket().deleteFiles({prefix, force: true});
  }
  await db().recursiveDelete(ref.collection("runs"));
  await ref.update({status: "deleted", title: "削除済み", originalHash: admin.firestore.FieldValue.delete(), noteText: admin.firestore.FieldValue.delete(), activeRun: admin.firestore.FieldValue.delete(), updatedAt: now()});
}
export const aiDeleteSource = callable(async (uid, data) => {
  const {ref} = await owned(uid, data.sourceId);
  await ref.update({status: "deleting", leaseToken: null, updatedAt: now()});
  await purge(ref);
  return {sourceId: ref.id, status: "deleted"};
});

export const aiRetrieveContext = callable(async (uid, data) => {
  const course = id(data.courseOfferingId);
  const lectureIds: string[] = data.lectureIds === undefined ? [] : data.lectureIds;
  if (!Array.isArray(lectureIds) || lectureIds.length > 30) throw new InputError("INVALID_LECTURES");
  lectureIds.forEach(id);
  const purpose = data.purpose || "question";
  if (!["question", "lecture_summary", "exam_review"].includes(purpose)) throw new InputError("INVALID_PURPOSE");
  const queryText = purpose === "question" ? str(data.query, "QUERY", 2000) : "";
  const budget = integer(data.maxCharacters ?? 12000, "BUDGET", 1500, 30000);
  const member = await verified(uid, course);
  let query = sources().where("courseOfferingId", "==", course).orderBy(admin.firestore.FieldPath.documentId()).limit(31);
  if (data.after) query = query.startAfter(id(data.after));
  const snap = await query.get();
  const visible = snap.docs.slice(0, 30).map(d => d.data()).filter(s => canRead(s, uid, member) && (!lectureIds.length || lectureIds.includes(s.lectureId)));
  const candidates: any[] = [];
  let truncated = snap.size > 30;
  for (const s of visible.filter(s => ["ready", "partial_ready"].includes(s.status) && s.activeRun)) {
    const chunks = await sources().doc(s.sourceId).collection("runs").doc(s.activeRun).collection("chunks").orderBy("chunkId").limit(81).get();
    if (chunks.size > 80) truncated = true;
    for (const chunk of chunks.docs.slice(0, 80)) candidates.push({...chunk.data(), sourceId: s.sourceId, sourceVersion: s.sourceVersion,
      lectureId: s.lectureId, sourceType: s.sourceType, activeVersion: s.activeRun, run: s.activeRun});
  }
  // Re-read authority after retrieval; no context cache bypasses revocation.
  const stillMember = await verified(uid, course);
  const latest = visible.length ? await db().getAll(...visible.map(s => sources().doc(s.sourceId))) : [];
  const allowed = new Map(latest.filter(d => d.exists && canRead(d.data(), uid, stillMember)).map(d => [d.id, d.data()!]));
  const selected = selectContext(candidates.filter(c => allowed.get(c.sourceId)?.activeRun === c.run), purpose, queryText, budget);
  const coverageSources = [...allowed.values()];
  return {schemaVersion: 1, contextRevision: hash(coverageSources.map(s => [s.sourceId, s.activeRun, s.updatedAt])),
    items: selected.items.map(({run, ...item}) => item), retrievalMethod: "lexical-ja-v1",
    truncated: truncated || selected.truncated, nextCursor: snap.size > 30 ? snap.docs[29].id : null,
    coverage: {readySources: coverageSources.filter(s => s.status === "ready").length,
      processingSources: coverageSources.filter(s => !terminal.includes(s.status)).length,
      partialSources: coverageSources.filter(s => s.status === "partial_ready").length,
      sources: coverageSources.map(s => ({sourceId: s.sourceId, status: s.status, coverage: s.coverage || null}))}};
});

export const aiProcessSource = onTaskDispatched({region, serviceAccount: runtimeAccount, timeoutSeconds: 1800, memory: "2GiB", maxInstances: 3,
  retryConfig: {maxAttempts: 4, minBackoffSeconds: 30, maxBackoffSeconds: 300}, rateLimits: {maxConcurrentDispatches: 3}}, async request => {
  const ref = sources().doc(id(request.data.sourceId)), token = randomUUID();
  const source = await db().runTransaction(async tx => {
    const s = (await tx.get(ref)).data();
    if (!s || terminal.includes(s.status) || s.status === "awaiting_upload") return null;
    if ((s.leaseUntil || 0) > now()) throw new InputError("BUSY", true);
    if (s.attempts >= 6) { tx.update(ref, {status: "failed", error: {code: "RETRY_LIMIT", retryable: false}}); return null; }
    tx.update(ref, {status: "extracting", leaseToken: token, leaseUntil: now() + 1900000, attempts: s.attempts + 1, updatedAt: now()});
    return s;
  });
  if (!source) return;
  const dir = await mkdtemp(join(tmpdir(), "ai-input-"));
  const derived = `ai-derived/${source.ownerUserId}/${ref.id}`;
  async function alive() { if (!mayPublish((await ref.get()).data(), token)) throw new InputError("CANCELLED"); }
  const cp = {
    alive,
    load: async (key: string) => { try { const [b] = await bucket().file(`${derived}/checkpoints/${PIPELINE}/${key}.json`).download(); return JSON.parse(b.toString()); } catch (e: any) { if (e.code === 404) return undefined; throw e; } },
    save: async (key: string, value: any) => { await alive(); await bucket().file(`${derived}/checkpoints/${PIPELINE}/${key}.json`).save(JSON.stringify(value), {contentType: "application/json"}); await alive(); }
  };
  try {
    let extraction: Extraction;
    const processingStartedAt = now();
    let originalHash: string | null = null;
    if (source.sourceType === "note") extraction = {units: [{text: source.noteText, locator: {startChar: 0, endChar: source.noteText.length}, method: "note", flags: []}], totalUnits: 1, failedUnits: []};
    else {
      const path = join(dir, "original");
      await bucket().file(source.storagePath, {generation: source.objectGeneration}).download({destination: path});
      const bytes = await readFile(path);
      originalHash = createHash("sha256").update(bytes).digest("hex");
      if (bytes.length !== source.declaredSize) throw new InputError("UPLOAD_MISMATCH");
      const pdfMagic = bytes.subarray(0, 5).toString() === "%PDF-";
      if (source.sourceType === "pdf" && !pdfMagic) throw new InputError("INVALID_PDF");
      if (source.sourceType === "image") extraction = await extractImage(path, cp);
      else if (source.sourceType === "pdf") extraction = await extractPDF(path, `gs://${bucket().name}/${source.storagePath}`, cp);
      else {
        const duration = await audioDuration(path);
        if (duration > source.declaredDuration + 1) throw new InputError("DURATION_MISMATCH");
        extraction = await extractAudio(path, duration, await groqSecret(), cp);
      }
    }
    await alive();
    const chunks = chunksFor(extraction.units);
    if (!chunks.length) throw new InputError("SOURCE_UNREADABLE");
    await db().runTransaction(async tx => { const s = (await tx.get(ref)).data(); if (!mayPublish(s, token)) throw new InputError("CANCELLED"); tx.update(ref, {status: "indexing"}); });
    await bucket().file(`${derived}/runs/${token}/extraction.json`).save(JSON.stringify(extraction), {contentType: "application/json"});
    for (let offset = 0; offset < chunks.length; offset += 200) {
      await alive(); const batch = db().batch();
      chunks.slice(offset, offset + 200).forEach(c => batch.set(ref.collection("runs").doc(token).collection("chunks").doc(c.chunkId), c));
      await batch.commit();
    }
    await db().runTransaction(async tx => {
      const s = (await tx.get(ref)).data(); if (!mayPublish(s, token)) throw new InputError("CANCELLED");
      tx.update(ref, {activeRun: token, originalHash, processingMs: now() - processingStartedAt, status: extraction.failedUnits.length ? "partial_ready" : "ready", leaseToken: null, leaseUntil: 0,
        coverage: {totalUnits: extraction.totalUnits, processedUnits: extraction.totalUnits - extraction.failedUnits.length, failedUnits: extraction.failedUnits},
        error: null, updatedAt: now()});
    });
    if (source.sourceType === "audio" && !extraction.failedUnits.length) await bucket().file(source.storagePath).delete({ignoreNotFound: true});
  } catch (e) {
    const error = e instanceof InputError ? e : new InputError("PROCESSING_UNAVAILABLE", true);
    await db().runTransaction(async tx => {
      const s = (await tx.get(ref)).data();
      if (s && mayPublish(s, token)) tx.update(ref, {status: error.retryable && s.attempts < 4 ? "queued" : "failed", leaseToken: null, leaseUntil: 0,
        error: {code: error.code, retryable: error.retryable}, updatedAt: now()});
    });
    if (error.retryable) throw error;
  } finally {
    await rm(dir, {recursive: true, force: true});
    const current = (await ref.get()).data();
    if (current && ["deleting", "deleted"].includes(current.status)) await purge(ref);
  }
});

export const aiReconcileInputs = onSchedule({region, serviceAccount: runtimeAccount, schedule: "every 15 minutes", timeoutSeconds: 540}, async () => {
  const cutoff = now() - 15 * 60000;
  const jobs = await sources().where("status", "in", ["queued", "extracting", "indexing", "deleting", "awaiting_upload", "failed", "partial_ready"]).where("updatedAt", "<", cutoff).limit(100).get();
  for (const doc of jobs.docs) {
    const s = doc.data();
    if (s.status === "deleting") { await purge(doc.ref); continue; }
    if (now() - s.createdAt >= 24 * 3600000 && s.sourceType !== "note") {
      const expired = await db().runTransaction(async tx => {
        const latest = (await tx.get(doc.ref)).data();
        if (!latest || ["deleting", "deleted", "ready"].includes(latest.status) || now() - latest.createdAt < 24 * 3600000) return false;
        tx.update(doc.ref, {status: latest.activeRun ? "partial_ready" : "failed", leaseToken: null, leaseUntil: 0,
          error: {code: "RAW_EXPIRED", retryable: false}, updatedAt: now()});
        return true;
      });
      if (expired) await bucket().file(s.storagePath).delete({ignoreNotFound: true});
      continue;
    }
    if (s.status === "queued" || (["extracting", "indexing"].includes(s.status) && s.leaseUntil < now())) {
      await db().runTransaction(async tx => {
        const latest = (await tx.get(doc.ref)).data()!;
        if (latest && ["extracting", "indexing"].includes(latest.status) && latest.leaseUntil < now()) tx.update(doc.ref, {status: "queued", leaseToken: null, leaseUntil: 0});
      });
      if ((await doc.ref.get()).get("status") === "queued") await enqueue(doc.id);
    }
  }
});
// A signed upload URL can finish after deletion. Remove late objects too.
export const aiRejectLateUpload = onObjectFinalized({region, serviceAccount: runtimeAccount}, async event => {
  const name = event.data.name || "";
  const match = /^ai-inputs\/([^/]+)\/([a-f0-9]{64})\/(?:original|audio\/original\.m4a)$/.exec(name);
  if (!match) return;
  const s = (await sources().doc(match[2]).get()).data();
  if (!s || s.ownerUserId !== match[1] || ["deleting", "deleted"].includes(s.status)) {
    await admin.storage().bucket(event.data.bucket).file(name, {generation: Number(event.data.generation)}).delete({ignoreNotFound: true});
  }
});
