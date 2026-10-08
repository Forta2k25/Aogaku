// Public admission is opt-in and fails closed without App Check enforcement.
export function admissionAllowed(project: string, mode: string, rawUIDs: string, enforceAppCheck: boolean, uid: string) {
  if (!uid || !/^[A-Za-z0-9_-]{1,128}$/.test(uid)) return false;
  if (mode === "public") return enforceAppCheck;
  if (mode !== "pilot") return false;
  if (project !== "forta-aogaku") return true;
  try { const values = JSON.parse(rawUIDs); return Array.isArray(values) && values.length > 0 &&
    values.every(v => typeof v === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(v)) && values.includes(uid); }
  catch { return false; }
}
export const INPUT_QUOTAS = {dailyCount: 100, dailyBytes: 500 * 1024 ** 2, weeklyAudioSeconds: 10800,
  requestsPerMinute: 120, providerCallsPerDay: 100};
