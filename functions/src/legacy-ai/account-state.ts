// Legacy AI admission only. No ingestion handlers, Tasks, OCR/ASR worker, or
// named database writes are imported into the old three callable Functions.
import * as admin from "firebase-admin";
import {getFirestore} from "firebase-admin/firestore";
import * as functions from "firebase-functions/v1";

export const defaultDatabase = () => getFirestore(admin.app(), "(default)");
export const accountDeletionFence = (uid: string) => defaultDatabase().doc(`accountDeletionFences/${uid}`);

export async function assertAccountActive(uid: string) {
  if (process.env.AI_FIRESTORE_DATABASE_ID && process.env.AI_FIRESTORE_DATABASE_ID !== "aogaku-ai") {
    throw new functions.https.HttpsError("failed-precondition", "AI_DATABASE_MISMATCH");
  }
  const [marker, fence] = await Promise.all([
    getFirestore(admin.app(), "aogaku-ai").doc(`aiInputOwners/${uid}`).get(),
    accountDeletionFence(uid).get(),
  ]);
  if ([marker, fence].some(s => ["deleting", "deleted"].includes(s.get("state")))) {
    throw new functions.https.HttpsError("failed-precondition", "ACCOUNT_DELETED");
  }
  try {
    const user = await admin.auth().getUser(uid);
    if (user.disabled) throw new functions.https.HttpsError("failed-precondition", "ACCOUNT_DISABLED");
  } catch (e: any) {
    if (e.code !== "auth/user-not-found") throw e;
    // Also fences legacy quota transactions. The named tombstone belongs to
    // the account-deletion flow (Phase 3b), never to legacy AI ingestion.
    await accountDeletionFence(uid).set({state: "deleting", updatedAt: admin.firestore.FieldValue.serverTimestamp()}, {merge: true});
    throw new functions.https.HttpsError("failed-precondition", "ACCOUNT_DELETED");
  }
}
