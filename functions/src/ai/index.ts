import * as admin from "firebase-admin";
import {onCall, HttpsError} from "firebase-functions/v2/https";
import {onTaskDispatched} from "firebase-functions/v2/tasks";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {onObjectFinalized} from "firebase-functions/v2/storage";
import {defineString, defineBoolean} from "firebase-functions/params";
import {getFunctions} from "firebase-admin/functions";
import {beginAIAccountDeletion, continueAIAccountDeletion, purge} from "./account-deletion";
export {beginAIAccountDeletion, continueAIAccountDeletion} from "./account-deletion";
import {randomUUID, createHash} from "node:crypto";
import {mkdtemp, rm, readFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {PIPELINE, InputError, validateCreate, id, offeringId, syllabusYear, courseSnapshot, CourseSnapshot, str, integer, hash, canRead, mayPublish, chunksFor, weekKey, selectContext, Extraction} from "./domain";
import {extractAudio, extractImage, extractPDF, audioDuration} from "./extractors";
import {AI_COLLECTIONS as collections} from "./schema";
import {admissionAllowed, INPUT_QUOTAS} from "./admission";
import {RecognitionError} from "./recognition";
import {IMAGE_PIPELINE} from "./pricing";
import {AUTO_CAPABILITIES} from "./visualRouter";
import {extractAutoImage, extractAutoPDF} from "./visualExtraction";
import {aiDatabase as db, defaultDatabase, aiDatabaseId, accountDeletionFence, rawPrefix, derivedPrefix} from "./databases";

const region = "asia-northeast1";
const runtimeAccount = defineString("AI_RUNTIME_SERVICE_ACCOUNT");
const pilotUIDs = defineString("AI_INPUT_ALLOWED_UIDS", {default: "[]"});
const admissionMode = defineString("AI_INPUT_ADMISSION_MODE", {default: "pilot"});
const requireAppCheck = defineBoolean("AI_INPUT_REQUIRE_APP_CHECK", {default: false});
// Parameter defaults are deployment-time hints; source-only artifacts need explicit safe runtime defaults.
const inputAdmissionMode = () => process.env.AI_INPUT_ADMISSION_MODE === undefined ? "pilot" : admissionMode.value();
const appCheckRequired = () => process.env.AI_INPUT_REQUIRE_APP_CHECK === "true" && requireAppCheck.value();
export function productionInputsAllowed(uid: string) {
  return admissionAllowed(runtimeProject(), inputAdmissionMode(), pilotUIDs.value(), appCheckRequired(), uid);
}
export function productionClosed() {
  if (inputAdmissionMode() === "public") return !appCheckRequired();
  if (inputAdmissionMode() !== "pilot") return true;
  if (runtimeProject() !== "forta-aogaku") return false;
  try {
    const allowed = JSON.parse(pilotUIDs.value());
    return !Array.isArray(allowed) || !allowed.length || allowed.some(uid => !productionInputsAllowed(uid));
  } catch { return true; }
}
const sharingFlag = defineBoolean("AI_SHARING_ENABLED", {default: false});
// Initial production is private-only, even if a flag is accidentally enabled.
export function sharingEnabled() { return runtimeProject() !== "forta-aogaku" && sharingFlag.value(); }
const owners = () => db().collection(collections.owners);
const bucket = () => admin.storage().bucket();
const sources = () => db().collection(collections.sources);
const now = () => Date.now();
const terminal = ["ready", "partial_ready", "failed", "deleting", "deleted"];
const queue = () => getFunctions().taskQueue(`locations/${region}/functions/aiProcessSource`);
function callable(fn: (uid: string, data: any) => Promise<any>) {
  return onCall({region, serviceAccount: runtimeAccount, cpu: "gcf_gen1", timeoutSeconds: 120, maxInstances: 10, enforceAppCheck: process.env.AI_INPUT_REQUIRE_APP_CHECK === "true"}, async request => {
    if (!request.auth) throw new HttpsError("unauthenticated", "認証を確認できませんでした。もう一度お試しください");
    try { if (inputAdmissionMode() === "public" && (!appCheckRequired() || !request.app)) throw new InputError("APP_CHECK_REQUIRED");
      if (!productionInputsAllowed(request.auth.uid)) throw new InputError("AI_INPUT_NOT_ENABLED");
      if (!request.data || typeof request.data !== "object") throw new InputError("INVALID_REQUEST");
      await assertAccountActive(request.auth.uid);
      await limitRequests(request.auth.uid);
      return await fn(request.auth.uid, request.data); }
    catch (e) {
      if (e instanceof HttpsError) throw e;
      if (e instanceof InputError) throw new HttpsError(e.code === "NOT_FOUND" ? "not-found" : e.code === "FORBIDDEN" ? "permission-denied" : "failed-precondition", e.code, {code: e.code, retryable: e.retryable});
      console.error("AI input failure", e instanceof Error ? e.name : "unknown");
      throw new HttpsError("internal", "処理に失敗しました。再試行してください", {code: "INTERNAL", retryable: true});
    }
  });
}
// Counters remain in the existing named-DB periods subtree and are removed by account cleanup.
async function limitRequests(uid: string) {
  const ref = db().doc(`${collections.usage}/${uid}/${collections.periods}/request-rate`), slot = Math.floor(now() / 60000);
  await db().runTransaction(async tx => {
    const [current, owner] = await Promise.all([tx.get(ref), tx.get(owners().doc(uid))]);
    if (["deleting", "deleted"].includes(owner.get("state"))) throw new InputError("ACCOUNT_DELETED");
    const count = current.get("slot") === slot ? current.get("count") || 0 : 0;
    if (count >= INPUT_QUOTAS.requestsPerMinute) throw new InputError("RATE_LIMITED", true);
    tx.set(ref, {slot, count: count + 1});
  });
}
async function reserveProviderCall(uid: string) {
  await assertAccountActive(uid);
  const day = new Date(now() + 9 * 3600000).toISOString().slice(0, 10);
  const ref = db().doc(`${collections.usage}/${uid}/${collections.periods}/day-${day}`);
  await db().runTransaction(async tx => {
    const [current, owner] = await Promise.all([tx.get(ref), tx.get(owners().doc(uid))]);
    if (["deleting", "deleted"].includes(owner.get("state"))) throw new InputError("ACCOUNT_DELETED");
    const count = current.get("providerCalls") || 0;
    if (count >= INPUT_QUOTAS.providerCallsPerDay) throw new InputError("PROVIDER_QUOTA_EXCEEDED");
    tx.set(ref, {providerCalls: count + 1}, {merge: true});
  });
}
async function verified(uid: string, courseId: string) {
  if (!sharingEnabled()) return false;
  const s = await db().doc(`${collections.offerings}/${courseId}/${collections.memberships}/${uid}`).get();
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
  return {databaseId: aiDatabaseId(), sourceId, sourceType, title, courseOfferingId, lectureId, dayID, status, courseSnapshot: s.courseSnapshot || null,
    canonicalSnapshot: s.canonicalSnapshot || null, pipelineVersion: s.pipelineVersion || "input-v1", recognition: s.recognition || null, processingMs: s.processingMs ?? null, sharingEnabled: sharingEnabled(), linkingEnabled: runtimeProject() !== "forta-aogaku", error: error || null,
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
  // ADC + secret-scoped IAM. Image and audio only; never expose the payload to clients.
  const response = await adcRequest(`https://secretmanager.googleapis.com/v1/projects/${runtimeProject()}/secrets/GROQ_API_KEY/versions/latest:access`);
  if (response.status === 404) throw new InputError("ASR_NOT_CONFIGURED");
  if (!response.ok) throw new InputError("ASR_SECRET_UNAVAILABLE", response.status === 429 || response.status >= 500);
  const payload = await response.json() as any;
  const key = Buffer.from(payload.payload?.data || "", "base64").toString("utf8").trim();
  if (!key) throw new InputError("ASR_NOT_CONFIGURED");
  return key;
}
// Durable task IDs permit deletion, including enqueue/delete races.
async function enqueue(sourceId: string) {
  const ref = sources().doc(sourceId), taskId = hash(sourceId, randomUUID());
  const job = ref.collection(collections.jobs).doc(taskId);
  const accepted = await db().runTransaction(async tx => {
    const s = (await tx.get(ref)).data();
    if (!s || s.status !== "queued" || !productionInputsAllowed(s.ownerUserId)) return false;
    const owner = await tx.get(owners().doc(s.ownerUserId));
    if (["deleting", "deleted"].includes(owner.get("state"))) return false;
    tx.set(job, {taskId, createdAt: now()}); return true;
  });
  if (!accepted) return;
  await queue().enqueue({sourceId, taskId, databaseId: aiDatabaseId()}, {id: taskId, dispatchDeadlineSeconds: 1800, uri: await taskTarget()});
  const latest = (await ref.get()).data();
  if (!latest || ["deleting", "deleted"].includes(latest.status)) { await queue().delete(taskId); await job.delete(); return; }
  await ref.update({lastEnqueuedAt: now()});
}
export async function assertAccountActive(uid: string) {
  const [marker, fence] = await Promise.all([owners().doc(uid).get(), accountDeletionFence(uid).get()]);
  if ([marker, fence].some(s => ["deleting", "deleted"].includes(s.get("state")))) throw new InputError("ACCOUNT_DELETED");
  try { const user = await admin.auth().getUser(uid); if (user.disabled) throw new InputError("ACCOUNT_DISABLED"); }
  catch (e: any) {
    if (e.code !== "auth/user-not-found") throw e;
    await owners().doc(uid).set({state: "deleting", updatedAt: now()}, {merge: true});
    await accountDeletionFence(uid).set({state: "deleting", updatedAt: now()}, {merge: true});
    throw new InputError("ACCOUNT_DELETED");
  }
}
async function reconcileAccounts() {
  // Continue interrupted deletion first; bounded work per scheduled invocation.
  const pending = await owners().where("state", "==", "deleting").limit(10).get();
  for (const owner of pending.docs) await continueAIAccountDeletion(owner.id);
  const cursor = db().doc(`${collections.maintenance}/accountSweep`), previous = await cursor.get();
  let query = owners().orderBy(admin.firestore.FieldPath.documentId()).limit(25);
  if (previous.get("after")) query = query.startAfter(previous.get("after"));
  const page = await query.get();
  for (const owner of page.docs) {
    if (owner.get("state") !== "active") continue;
    try { await assertAccountActive(owner.id); }
    catch (e) { if (e instanceof InputError && e.code === "ACCOUNT_DELETED") await continueAIAccountDeletion(owner.id); else if (!(e instanceof InputError && e.code === "ACCOUNT_DISABLED")) throw e; }
  }
  await cursor.set({after: page.size === 25 ? page.docs.at(-1)!.id : null, updatedAt: now()});
}

async function uploadInfo(source: any) {
  if (source.sourceType === "note" || source.status !== "awaiting_upload") return null;
  const [url] = await bucket().file(source.storagePath).getSignedUrl({version: "v4", action: "write", expires: now() + 10 * 60 * 1000,
    contentType: source.mime, extensionHeaders: {"x-goog-if-generation-match": "0"}});
  return {url, headers: {"Content-Type": source.mime, "x-goog-if-generation-match": "0"}};
}

async function resolveContext(uid: string, context: ReturnType<typeof validateCreate>["context"], creating = false) {
  let c = {...context};
  // Validate before constructing a document path. Lookup always uses the frozen client context.
  courseSnapshot(uid, c);
  if (creating && c.classDocId) {
    const catalog = await defaultDatabase().collection("classes").doc(c.classDocId).get();
    if (!catalog.exists) {
      const archived = courseSnapshot(uid, c);
      if (archived.resolution !== "canonical" || !(await db().doc(`${collections.offerings}/${archived.courseOfferingId}`).get()).exists) throw new InputError("CLASS_NOT_FOUND");
    } else if (!c.syllabusUrl) {
      const url = catalog.get("url") || catalog.get("syllabusURL") || "";
      const catalogYear = syllabusYear(url);
      // Never attach an old timetable to a recycled current-year document silently.
      if (catalogYear !== null && c.year !== undefined && c.year !== catalogYear) throw new InputError("CLASS_YEAR_MISMATCH");
      c = {...c, syllabusUrl: url, courseName: c.courseName || catalog.get("class_name") || catalog.get("title") || "",
        teacherName: c.teacherName || catalog.get("teacher_name") || ""};
    }
  }
  const snapshot = courseSnapshot(uid, c);
  const courseOfferingId = snapshot.courseOfferingId;
  return {courseOfferingId, lectureId: hash(courseOfferingId, c.semester, c.dayID, c.occurrenceKey), snapshot};
}

export const aiCreateSource = callable(async (uid, data) => {
  const input = validateCreate(data);
  const c = input.context;
  const sourceId = hash(uid, input.clientRequestId);
  const ref = sources().doc(sourceId), fingerprint = hash(input);
  // Retry an existing receipt without re-resolving live classes, including legacy Dev receipts.
  const accepted = await ref.get();
  if (accepted.exists) {
    if (accepted.get("fingerprint") !== fingerprint) throw new InputError("REQUEST_CONFLICT");
    if (["deleted", "deleting"].includes(accepted.get("status"))) throw new InputError("SOURCE_DELETED");
    const existing = accepted.data()!;
    if (existing.status === "queued") await enqueue(sourceId);
    return {...publicSource(existing), upload: await uploadInfo(existing)};
  }
  const {courseOfferingId, lectureId, snapshot} = await resolveContext(uid, c, true);
  const day = new Date(now() + 9 * 3600000).toISOString().slice(0, 10);
  const usageRef = db().doc(`${collections.usage}/${uid}/${collections.periods}/day-${day}`);
  const audioRef = db().doc(`${collections.usage}/${uid}/${collections.periods}/week-${weekKey(new Date())}`);
  const source = await db().runTransaction(async tx => {
    const existing = await tx.get(ref);
    if (existing.exists) {
      if (existing.get("fingerprint") !== fingerprint) throw new InputError("REQUEST_CONFLICT");
      if (["deleted", "deleting"].includes(existing.get("status"))) throw new InputError("SOURCE_DELETED");
      return existing.data()!;
    }
    const offeringRef = db().doc(`${collections.offerings}/${courseOfferingId}`);
    const ownerRef = owners().doc(uid);
    const [daily, weekly, offering, owner] = await Promise.all([tx.get(usageRef), tx.get(audioRef), tx.get(offeringRef), tx.get(ownerRef)]);
    if (["deleting", "deleted"].includes(owner.get("state"))) throw new InputError("ACCOUNT_DELETED");
    const bytes = daily.get("bytes") || 0, count = daily.get("count") || 0, seconds = weekly.get("seconds") || 0;
    const reservation = input.durationSeconds || 0;
    if (count >= INPUT_QUOTAS.dailyCount || bytes + input.size > INPUT_QUOTAS.dailyBytes || seconds + reservation > INPUT_QUOTAS.weeklyAudioSeconds) throw new InputError("QUOTA_EXCEEDED");
    const source = {sourceId, sourceVersion: 1, schemaVersion: 5, pipelineVersion: input.type === "image" ? "image-auto-v1" : input.type === "pdf" ? "pdf-auto-v1" : input.type === "audio" ? "audio-groq-v2" : PIPELINE,
      fingerprint, ownerUserId: uid, courseOfferingId, lectureId, dayID: c.dayID, courseSnapshot: snapshot,
      occurrenceKey: c.occurrenceKey,
      sourceType: input.type, title: input.title, mime: input.mime, declaredSize: input.size,
      declaredDuration: reservation, audioUsagePath: audioRef.path,
      rawVisibility: "private", knowledgeVisibility: "private", status: input.type === "note" ? "queued" : "awaiting_upload",
      databaseId: aiDatabaseId(), storagePath: `${rawPrefix(uid, sourceId)}${input.type === "audio" ? "audio/original.m4a" : "original"}`, createdAt: now(), updatedAt: now(), attempts: 0,
      ...(input.text ? {noteText: input.text} : {})};
    tx.set(ref, source);
    if (!owner.exists) tx.set(ownerRef, {state: "active", createdAt: now()});
    tx.set(usageRef, {bytes: bytes + input.size, count: count + 1});
    if (reservation) tx.set(audioRef, {seconds: seconds + reservation});
    // Offering metadata is first-write only. Each source keeps its own immutable snapshot.
    if (!offering.exists) tx.set(offeringRef, {...snapshot, createdAt: now()});
    tx.set(db().doc(`${collections.offerings}/${courseOfferingId}/${collections.lectures}/${lectureId}`), {dayID: c.dayID, occurrenceKey: c.occurrenceKey}, {merge: true});
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
  const course = resolved?.courseOfferingId || offeringId(data.courseOfferingId);
  const lecture = data.lectureId || (data.onlyLecture ? resolved?.lectureId : undefined);
  const after = data.after ? id(data.after) : undefined;
  let query = sources().where("courseOfferingId", "==", course).orderBy(admin.firestore.FieldPath.documentId()).limit(101);
  if (after) query = query.startAfter(after);
  const [snap, member] = await Promise.all([query.get(), verified(uid, course)]);
  const page = snap.docs.slice(0, 100);
  return {items: page.map(d => d.data()).filter(s => canRead(s, uid, member) && (!lecture || s.lectureId === lecture)).map(publicSource),
    inputCapabilities: AUTO_CAPABILITIES,
    courseOfferingId: course, lectureId: resolved?.lectureId || null, nextCursor: snap.size > 100 ? page.at(-1)!.id : null};
});
export const aiGetEvidence = callable(async (uid, data) => {
  const ref = sources().doc(id(data.sourceId)), source = (await ref.get()).data();
  if (!source || !canRead(source, uid, await verified(uid, source.courseOfferingId))) throw new InputError("NOT_FOUND");
  if (!source.activeRun) return {items: [], status: source.status, nextCursor: null};
  let q = ref.collection(collections.runs).doc(source.activeRun).collection(collections.chunks).orderBy("chunkId").limit(21);
  if (data.after) q = q.startAfter(id(data.after));
  const chunks = await q.get();
  const latest = (await ref.get()).data();
  if (!latest || latest.activeRun !== source.activeRun || !canRead(latest, uid, await verified(uid, source.courseOfferingId))) throw new InputError("NOT_FOUND");
  return {items: chunks.docs.slice(0, 20).map(d => ({...d.data(), sourceId: ref.id, lectureId: latest.lectureId})),
    status: latest.status, activeVersion: latest.activeRun, recognition: latest.recognition || null, pipelineVersion: latest.pipelineVersion || "input-v1", processingMs: latest.processingMs ?? null, coverage: latest.coverage || null, nextCursor: chunks.size > 20 ? chunks.docs[19].id : null};
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
    changes[key] = data[key];
  }
  await db().runTransaction(async tx => {
    const s = (await tx.get(ref)).data()!;
    if (["deleting", "deleted"].includes(s.status)) throw new InputError("SOURCE_DELETED");
    if (changes.rawVisibility === "course" || changes.knowledgeVisibility === "course") {
      if (!sharingEnabled()) throw new InputError("SHARING_DISABLED");
      if (s.courseSnapshot && s.courseSnapshot.resolution !== "canonical" && !s.canonicalSnapshot) throw new InputError("OFFERING_UNRESOLVED");
      const member = await tx.get(db().doc(`${collections.offerings}/${s.courseOfferingId}/${collections.memberships}/${uid}`));
      if (member.get("status") !== "verified" || member.get("active") !== true) throw new InputError("MEMBERSHIP_NOT_VERIFIED");
    }
    tx.update(ref, changes);
  });
  return publicSource((await ref.get()).data());
});

// An explicit owner action only; never a catalog-driven migration. Receipt and original snapshot stay intact.
export const aiLinkSourceOffering = callable(async (uid, data) => {
  if (runtimeProject() === "forta-aogaku") throw new InputError("LINKING_DISABLED");
  const {ref, source} = await owned(uid, data.sourceId);
  const classDocId = str(data.classDocId, "CLASS", 5);
  if (!/^\d{5}$/.test(classDocId)) throw new InputError("INVALID_CLASS");
  if (source.canonicalSnapshot) {
    if (source.canonicalSnapshot.classDocId !== classDocId ||
        (data.year !== undefined && data.year !== source.canonicalSnapshot.year)) throw new InputError("OFFERING_ALREADY_LINKED");
    return publicSource(source);
  }
  const catalog = await defaultDatabase().doc(`classes/${classDocId}`).get();
  if (!catalog.exists) throw new InputError("CLASS_NOT_FOUND");
  const original: CourseSnapshot | undefined = source.courseSnapshot;
  const c = validateCreate({clientRequestId: "link", type: "note", title: "link", mime: "text/plain", text: "link",
    context: {localCourseUUID: original?.localCourseUUID || data.localCourseUUID, classDocId,
      syllabusUrl: catalog.get("url") || catalog.get("syllabusURL") || "", year: original?.year ?? data.year,
      semester: original?.semester || data.semester, dayID: source.dayID,
      courseName: catalog.get("class_name") || catalog.get("title") || "", teacherName: catalog.get("teacher_name") || ""}}).context;
  const target = courseSnapshot(uid, c);
  if (target.resolution !== "canonical") throw new InputError("OFFERING_UNRESOLVED");
  if (original?.year !== null && original?.year !== undefined && original.year !== target.year) throw new InputError("CLASS_YEAR_MISMATCH");
  const lectureId = hash(target.courseOfferingId, target.semester, source.dayID, source.occurrenceKey || "default");
  await db().runTransaction(async tx => {
    const latest = await tx.get(ref);
    const s = latest.data()!;
    const offeringRef = db().doc(`${collections.offerings}/${target.courseOfferingId}`);
    const offering = await tx.get(offeringRef);
    if (!["ready", "partial_ready", "failed", "awaiting_upload"].includes(s.status)) throw new InputError("SOURCE_BUSY");
    if (s.canonicalSnapshot) {
      if (s.canonicalSnapshot.courseOfferingId !== target.courseOfferingId) throw new InputError("OFFERING_ALREADY_LINKED");
      return; // a racing/repeated link never replaces the first link snapshot
    }
    if (s.courseSnapshot?.resolution === "canonical" && s.courseOfferingId !== target.courseOfferingId) throw new InputError("OFFERING_ALREADY_LINKED");
    tx.update(ref, {courseOfferingId: target.courseOfferingId, lectureId, canonicalSnapshot: target,
      linkedFromOfferingId: s.linkedFromOfferingId || s.courseOfferingId, linkedAt: now(), updatedAt: now(),
      rawVisibility: "private", knowledgeVisibility: "private"});
    if (!offering.exists) tx.set(offeringRef, {...target, createdAt: now()});
    tx.set(offeringRef.collection(collections.lectures).doc(lectureId), {dayID: source.dayID, occurrenceKey: source.occurrenceKey || "default"}, {merge: true});
  });
  return publicSource((await ref.get()).data());
});

export const aiDeleteSource = callable(async (uid, data) => {
  const {ref} = await owned(uid, data.sourceId);
  await ref.update({status: "deleting", leaseToken: null, updatedAt: now()});
  await purge(ref);
  return {sourceId: ref.id, status: "deleted"};
});

export const aiRetrieveContext = callable(async (uid, data) => {
  const course = offeringId(data.courseOfferingId);
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
    const chunks = await sources().doc(s.sourceId).collection(collections.runs).doc(s.activeRun).collection(collections.chunks).orderBy("chunkId").limit(81).get();
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
  // Old default-DB deliveries cannot touch the new namespace, even on ID reuse.
  if (request.data.databaseId !== aiDatabaseId()) return;
  if (productionClosed()) throw new InputError("AI_INPUT_NOT_ENABLED");
  const ref = sources().doc(id(request.data.sourceId)), token = randomUUID();
  const source = await db().runTransaction(async tx => {
    const s = (await tx.get(ref)).data();
    if (!s || terminal.includes(s.status) || s.status === "awaiting_upload" || !productionInputsAllowed(s.ownerUserId)) return null;
    if ((s.leaseUntil || 0) > now()) throw new InputError("BUSY", true);
    if (s.attempts >= 6) { tx.update(ref, {status: "failed", error: {code: "RETRY_LIMIT", retryable: false}}); return null; }
    tx.update(ref, {status: "extracting", leaseToken: token, leaseUntil: now() + 1900000, attempts: s.attempts + 1, updatedAt: now()});
    return s;
  });
  if (!source) { if (request.data.taskId) await ref.collection(collections.jobs).doc(id(request.data.taskId)).delete(); return; }
  try { await assertAccountActive(source.ownerUserId); }
  catch (e) {
    if (e instanceof InputError && e.code === "ACCOUNT_DELETED") { await ref.update({status: "deleting", leaseToken: null}); await purge(ref); return; }
    throw e;
  }
  const ownerUID = source.ownerUserId;
  const dir = await mkdtemp(join(tmpdir(), "ai-input-"));
  const derived = derivedPrefix(source.ownerUserId, ref.id).replace(/\/$/, "");
  async function alive() {
    if (!productionInputsAllowed(ownerUID)) throw new InputError("CANCELLED");
    const marker = await owners().doc(ownerUID).get();
    if (["deleting", "deleted"].includes(marker.get("state")) || !mayPublish((await ref.get()).data(), token)) throw new InputError("CANCELLED");
  }
  const cp = {
    alive,
    reserveProviderCall: () => reserveProviderCall(ownerUID),
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
      if (source.sourceType === "image") extraction = source.pipelineVersion === "image-auto-v1" ?
        await extractAutoImage(path, await groqSecret(), cp) : await extractImage(path, source.mime, await groqSecret(), cp);
      else if (source.sourceType === "pdf") extraction = source.pipelineVersion === "pdf-auto-v1" ?
        await extractAutoPDF(path, await groqSecret(), cp) : await extractPDF(path, `gs://${bucket().name}/${source.storagePath}`, cp);
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
    // New recognition runs retain metadata here; final text lives in chunks, with checkpoints only for resumable provider work.
    const runManifest = extraction.recognition ? {totalUnits: extraction.totalUnits, failedUnits: extraction.failedUnits, recognition: extraction.recognition} : extraction;
    await bucket().file(`${derived}/runs/${token}/extraction.json`).save(JSON.stringify(runManifest), {contentType: "application/json"});
    for (let offset = 0; offset < chunks.length; offset += 200) {
      await alive(); const batch = db().batch();
      chunks.slice(offset, offset + 200).forEach(c => batch.set(ref.collection(collections.runs).doc(token).collection(collections.chunks).doc(c.chunkId), c));
      await batch.commit();
    }
    await assertAccountActive(source.ownerUserId);
    await db().runTransaction(async tx => {
      const s = (await tx.get(ref)).data();
      const owner = await tx.get(owners().doc(source.ownerUserId));
      if (!productionInputsAllowed(source.ownerUserId) || ["deleting", "deleted"].includes(owner.get("state")) || !mayPublish(s, token)) throw new InputError("CANCELLED");
      tx.update(ref, {activeRun: token, originalHash, ...(extraction.recognition ? {recognition: extraction.recognition, pipelineVersion: extraction.recognition.pipelineVersion} : {}), processingMs: now() - processingStartedAt, status: extraction.failedUnits.length ? "partial_ready" : "ready", leaseToken: null, leaseUntil: 0,
        coverage: {totalUnits: extraction.totalUnits, processedUnits: extraction.totalUnits - extraction.failedUnits.length, failedUnits: extraction.failedUnits},
        error: null, updatedAt: now()});
    });
    if (source.sourceType === "audio" && !extraction.failedUnits.length) await bucket().file(source.storagePath).delete({ignoreNotFound: true});
  } catch (e) {
    const error = e instanceof InputError ? e : new InputError("PROCESSING_UNAVAILABLE", true);
    await db().runTransaction(async tx => {
      const s = (await tx.get(ref)).data();
      if (s && mayPublish(s, token)) tx.update(ref, {status: error.retryable && s.attempts < 4 ? "queued" : "failed", leaseToken: null, leaseUntil: 0,
        error: {code: error.code, retryable: error.retryable}, ...(error instanceof RecognitionError && error.recognition && !["image-auto-v1", "pdf-auto-v1"].includes(source.pipelineVersion) ? {recognition: error.recognition} : {}), updatedAt: now()});
    });
    if (error.retryable) throw error;
  } finally {
    if (request.data.taskId) await ref.collection(collections.jobs).doc(id(request.data.taskId)).delete();
    await rm(dir, {recursive: true, force: true});
    const current = (await ref.get()).data();
    if (current && ["deleting", "deleted"].includes(current.status)) await purge(ref);
  }
});

export const aiReconcileInputs = onSchedule({region, serviceAccount: runtimeAccount, cpu: "gcf_gen1", schedule: "every 15 minutes", timeoutSeconds: 540}, async () => {
  if (productionClosed()) return;
  await reconcileAccounts();
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
export const aiRejectLateUpload = onObjectFinalized({region, serviceAccount: runtimeAccount, cpu: "gcf_gen1", maxInstances: 3, retry: true}, async event => {
  const name = event.data.name || "";
  const match = /^ai-inputs\/aogaku-ai\/([^/]+)\/([a-f0-9]{64})\/(?:original|audio\/original\.m4a)$/.exec(name);
  if (!match) return;
  const s = (await sources().doc(match[2]).get()).data();
  const owner = await owners().doc(match[1]).get();
  let accountDeleted = ["deleting", "deleted"].includes(owner.get("state"));
  if (!accountDeleted && s) { try { await assertAccountActive(match[1]); } catch (e) { if (e instanceof InputError && e.code === "ACCOUNT_DELETED") accountDeleted = true; else throw e; } }
  if (!s || accountDeleted || s.ownerUserId !== match[1] || ["deleting", "deleted"].includes(s.status)) {
    await admin.storage().bucket(event.data.bucket).file(name, {generation: Number(event.data.generation)}).delete({ignoreNotFound: true});
  }
});
