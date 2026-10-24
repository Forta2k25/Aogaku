// Dedicated initial-production entry: exactly twelve AI exports. No legacy handlers.
import * as admin from "firebase-admin";
import * as ai from "./ai";
if (!admin.apps.length) admin.initializeApp();
export const aiCreateSource = ai.aiCreateSource;
export const aiCompleteSource = ai.aiCompleteSource;
export const aiGetSource = ai.aiGetSource;
export const aiListSources = ai.aiListSources;
export const aiGetEvidence = ai.aiGetEvidence;
export const aiRetrySource = ai.aiRetrySource;
export const aiUpdateSource = ai.aiUpdateSource;
export const aiDeleteSource = ai.aiDeleteSource;
export const aiRetrieveContext = ai.aiRetrieveContext;
export const aiProcessSource = ai.aiProcessSource;
export const aiReconcileInputs = ai.aiReconcileInputs;
// SDK 6.4 has no Storage trigger-region option. Adapt its deployment manifest only;
// runtime stays in Tokyo and the Eventarc trigger stays with the US-CENTRAL1 bucket.
const storageHandler = ai.aiRejectLateUpload;
export const aiRejectLateUpload = Object.assign(
  (event: Parameters<typeof storageHandler>[0]) => storageHandler(event), {run: storageHandler.run});
Object.defineProperty(aiRejectLateUpload, "__endpoint", {get: () => ({
  ...storageHandler.__endpoint,
  eventTrigger: {...storageHandler.__endpoint.eventTrigger,
    eventFilters: {bucket: "forta-aogaku.firebasestorage.app"}, region: "us-central1"}
})});
