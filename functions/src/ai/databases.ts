import * as admin from "firebase-admin";
import {getFirestore} from "firebase-admin/firestore";
import {defineString} from "firebase-functions/params";
import {InputError} from "./domain";

export const AI_DATABASE_ID = "aogaku-ai";
export const DEFAULT_DATABASE_ID = "(default)";
const configuredDatabase = defineString("AI_FIRESTORE_DATABASE_ID", {default: AI_DATABASE_ID});
export function aiDatabaseId() {
  // REST source-only updates do not inject Firebase CLI parameter defaults.
  // Only an absent variable selects the fixed named DB; explicit empty/wrong
  // values fail closed and can never redirect AI data to the default database.
  const raw = process.env.AI_FIRESTORE_DATABASE_ID;
  const id = raw === undefined ? AI_DATABASE_ID : configuredDatabase.value();
  if (id !== AI_DATABASE_ID) throw new InputError("AI_DATABASE_MISMATCH");
  return AI_DATABASE_ID;
}
export const aiDatabase = () => getFirestore(admin.app(), aiDatabaseId());
export const defaultDatabase = () => getFirestore(admin.app(), DEFAULT_DATABASE_ID);
// Common account fence for legacy quota transactions. No source content or AI
// usage lives in (default). This marker survives legacy user/quota cleanup.
export const accountDeletionFence = (uid: string) => defaultDatabase().doc(`accountDeletionFences/${uid}`);
export const rawPrefix = (uid: string, sourceId: string) => `ai-inputs/${aiDatabaseId()}/${uid}/${sourceId}/`;
export const derivedPrefix = (uid: string, sourceId: string) => `ai-derived/${aiDatabaseId()}/${uid}/${sourceId}/`;
