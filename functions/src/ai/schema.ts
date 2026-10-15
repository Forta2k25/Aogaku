// Canonical AI storage names. Never use the legacy public review collection
// "entries" here. This inventory does not block arbitrary client-created paths;
// that boundary must independently be enforced by Firestore Rules.
export const AI_COLLECTIONS = Object.freeze({
  sources: "aiSources",
  offerings: "aiCourseOfferings",
  usage: "aiUsage",
  owners: "aiInputOwners",
  maintenance: "aiMaintenance",
  jobs: "jobs",
  runs: "runs",
  chunks: "chunks",
  memberships: "memberships",
  lectures: "lectures",
  periods: "periods",
} as const);

export const AI_DOCUMENT_PATHS = Object.freeze([
  "aiSources/{sourceId}",
  "aiSources/{sourceId}/jobs/{taskId}",
  "aiSources/{sourceId}/runs/{runId}",
  "aiSources/{sourceId}/runs/{runId}/chunks/{chunkId}",
  "aiCourseOfferings/{courseOfferingId}",
  "aiCourseOfferings/{courseOfferingId}/memberships/{uid}",
  "aiCourseOfferings/{courseOfferingId}/lectures/{lectureId}",
  "aiUsage/{uid}",
  "aiUsage/{uid}/periods/{periodId}",
  "aiInputOwners/{uid}",
  "aiMaintenance/accountSweep",
] as const);
