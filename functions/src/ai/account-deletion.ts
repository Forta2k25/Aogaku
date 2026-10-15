// Shared cleanup only: no Callable, worker, provider, or Secret declarations.
import * as admin from "firebase-admin";
import {getFunctions} from "firebase-admin/functions";
import {AI_COLLECTIONS as collections} from "./schema";
import {aiDatabase as db, aiDatabaseId, accountDeletionFence, rawPrefix, derivedPrefix} from "./databases";
const owners = () => db().collection(collections.owners);
const sources = () => db().collection(collections.sources);
const bucket = () => admin.storage().bucket();
const now = () => Date.now();
const queue = () => getFunctions().taskQueue("locations/asia-northeast1/functions/aiProcessSource");
// Callable from the existing account-deletion implementation BEFORE Auth deletion.
// Internal helper connected by the recovered legacy-account deletion handlers.
export async function beginAIAccountDeletion(uid: string) {
  // Fence new AI first. A crash before the second write is resumed by Scheduler.
  // Auth removal never starts until this helper and both fences succeed.
  await owners().doc(uid).set({state: "deleting", updatedAt: now()}, {merge: true});
  await accountDeletionFence(uid).set({state: "deleting", updatedAt: now()}, {merge: true});
  await continueAIAccountDeletion(uid);
}
export async function continueAIAccountDeletion(uid: string) {
  const marker = owners().doc(uid), state = await marker.get();
  if (state.get("state") === "deleted") {
    await accountDeletionFence(uid).set({state: "deleted", updatedAt: now()}, {merge: true});
    return;
  }
  if (state.get("state") !== "deleting") return;
  // Repair the default fence BEFORE cleanup; refunds cannot recreate old quota.
  await accountDeletionFence(uid).set({state: "deleting", updatedAt: now()}, {merge: true});
  let query = sources().where("ownerUserId", "==", uid).orderBy(admin.firestore.FieldPath.documentId()).limit(25);
  if (state.get("cleanupCursor")) query = query.startAfter(state.get("cleanupCursor"));
  const page = await query.get();
  for (const doc of page.docs) {
    await doc.ref.update({status: "deleting", leaseToken: null, updatedAt: now()});
    await purge(doc.ref);
    const s = doc.data();
    if (s.courseOfferingId) await db().doc(`${collections.offerings}/${s.courseOfferingId}/${collections.memberships}/${uid}`).delete();
    if (s.courseOfferingId?.startsWith("local:")) await db().recursiveDelete(db().doc(`${collections.offerings}/${s.courseOfferingId}`));
    // Keep a minimal non-content tombstone for receipt/late-task protection.
    await doc.ref.set({sourceId: doc.id, ownerUserId: uid, status: "deleted", updatedAt: now()});
    await marker.update({cleanupCursor: doc.id, updatedAt: now()});
  }
  if (page.size < 25) {
    // Verified memberships carry userId; group lookup includes missing parents.
    // A bounded delete is naturally resumable because deleted results disappear.
    const memberships = await db().collectionGroup(collections.memberships).where("userId", "==", uid).limit(100).get();
    const batch = db().batch();
    for (const membership of memberships.docs) batch.delete(membership.ref);
    await batch.commit();
    if (memberships.size === 100) return;
    await db().recursiveDelete(db().doc(`${collections.usage}/${uid}`));
    for (const prefix of [`ai-inputs/${aiDatabaseId()}/${uid}/`, `ai-derived/${aiDatabaseId()}/${uid}/`]) {
      await bucket().deleteFiles({prefix});
    }
    const sweep = db().doc(`${collections.maintenance}/accountSweep`);
    await db().runTransaction(async tx => {
      const snapshot = await tx.get(sweep);
      if (snapshot.get("after") === uid) tx.update(sweep, {after: null, updatedAt: now()});
    });
    await marker.set({state: "deleted", updatedAt: now()});
    await accountDeletionFence(uid).set({state: "deleted", updatedAt: now()}, {merge: true});
  }
}
export async function purge(ref: admin.firestore.DocumentReference) {
  const source = (await ref.get()).data();
  if (!source || !["deleting", "deleted"].includes(source.status)) return;
  const jobs = await ref.collection(collections.jobs).get();
  for (const job of jobs.docs) { await queue().delete(job.id); await job.ref.delete(); }
  for (const prefix of [rawPrefix(source.ownerUserId, ref.id), derivedPrefix(source.ownerUserId, ref.id)]) {
    await bucket().deleteFiles({prefix, force: true});
  }
  await db().recursiveDelete(ref.collection(collections.runs));
  await ref.update({status: "deleted", title: "削除済み", originalHash: admin.firestore.FieldValue.delete(), noteText: admin.firestore.FieldValue.delete(), activeRun: admin.firestore.FieldValue.delete(), updatedAt: now()});
}

// Existing deletion callbacks must finish without waiting for the Phase 4 Scheduler.
// Each page commits checkpoints; a failed invocation can be retried safely.
export async function finishAIAccountDeletion(uid: string) {
  const deadline = Date.now() + 420_000;
  await beginAIAccountDeletion(uid);
  while ((await owners().doc(uid).get()).get("state") === "deleting") {
    if (Date.now() >= deadline) throw new Error("AI_ACCOUNT_CLEANUP_RETRY_REQUIRED");
    await continueAIAccountDeletion(uid);
  }
  if ((await owners().doc(uid).get()).get("state") !== "deleted") throw new Error("AI_ACCOUNT_CLEANUP_INCOMPLETE");
}
