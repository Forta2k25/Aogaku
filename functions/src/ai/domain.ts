import {createHash} from "node:crypto";

export const PIPELINE = "input-v1";
export const LIMITS = {image: 10 * 1024 ** 2, pdf: 20 * 1024 ** 2, audio: 100 * 1024 ** 2, note: 80000};
export type SourceType = keyof typeof LIMITS;
export type Visibility = "private" | "course";
export type Status = "awaiting_upload" | "queued" | "extracting" | "indexing" | "ready" | "partial_ready" | "failed" | "deleting" | "deleted";
export type Locator = {pageNumber?: number; startMs?: number; endMs?: number; startChar?: number; endChar?: number; imageIndex?: number};
export interface Unit {text: string; locator: Locator; method: string; flags: string[]}
export interface Extraction {units: Unit[]; totalUnits: number; failedUnits: number[]; raw?: unknown}
export interface Chunk extends Unit {chunkId: string}
export class InputError extends Error {
  constructor(public code: string, public retryable = false) { super(code); }
}
export function hash(...parts: unknown[]): string {
  return createHash("sha256").update(JSON.stringify(parts)).digest("hex");
}
export function str(value: unknown, name: string, max = 200): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) throw new InputError(`INVALID_${name}`);
  return value.trim();
}
export function id(value: unknown): string {
  const result = str(value, "ID", 128);
  if (!/^[\w-]+$/.test(result)) throw new InputError("INVALID_ID");
  return result;
}
// Offering IDs have their own grammar; never loosen source/receipt/path IDs.
export function offeringId(value: unknown): string {
  const result = str(value, "OFFERING", 128);
  if (!/^(?:\d{4}:\d{5}|local:[a-f0-9]{64}|[\w-]+)$/.test(result)) throw new InputError("INVALID_OFFERING");
  return result; // old hashed offerings remain readable, never silently migrated
}
export function syllabusYear(url: unknown): number | null {
  if (typeof url !== "string" || !url) return null;
  try {
    const parsed = new URL(url);
    if (!["https:", "http:"].includes(parsed.protocol)) return null;
    const years = parsed.searchParams.getAll("YR");
    if (years.length !== 1 || !/^\d{4}$/.test(years[0])) return null;
    const year = Number(years[0]);
    return year >= 2000 && year <= 2100 ? year : null;
  } catch { return null; }
}
export interface OfferingContext {
  classDocId?: string; localCourseId: string; localCourseUUID?: string;
  year?: number; semester: string; dayID: number; occurrenceKey: string;
  syllabusUrl?: string; courseName?: string; teacherName?: string;
}
export interface CourseSnapshot {
  courseOfferingId: string; classDocId: string | null; year: number | null;
  semester: string; syllabusUrl: string | null; courseName: string; teacherName: string;
  localCourseUUID: string; resolution: "canonical" | "local" | "unresolved";
  yearSource: "syllabus" | "timetable" | "unresolved";
}
export function courseSnapshot(uid: string, c: OfferingContext): CourseSnapshot {
  if (c.classDocId && !/^\d{5}$/.test(c.classDocId)) throw new InputError("INVALID_CLASS");
  if (!c.localCourseUUID || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(c.localCourseUUID)) throw new InputError("LOCAL_COURSE_UUID_REQUIRED");
  const fromURL = syllabusYear(c.syllabusUrl);
  const year = fromURL ?? c.year ?? null;
  const uuid = c.localCourseUUID.toLowerCase();
  const canonical = !!c.classDocId && year !== null;
  return {courseOfferingId: canonical ? `${year}:${c.classDocId}` : `local:${hash(uid, uuid, year)}`,
    classDocId: c.classDocId || null, year, semester: c.semester, syllabusUrl: c.syllabusUrl || null,
    courseName: c.courseName || "", teacherName: c.teacherName || "", localCourseUUID: uuid,
    resolution: canonical ? "canonical" : year === null ? "unresolved" : "local",
    yearSource: fromURL !== null ? "syllabus" : year !== null ? "timetable" : "unresolved"};
}
export function integer(value: unknown, name: string, min: number, max: number): number {
  if (!Number.isSafeInteger(value) || Number(value) < min || Number(value) > max) throw new InputError(`INVALID_${name}`);
  return Number(value);
}
export interface CreateInput {
  clientRequestId: string; type: SourceType; title: string; size: number;
  mime: string; text?: string; durationSeconds?: number;
  context: OfferingContext;
}
export function validateCreate(data: any): CreateInput {
  if (!data || typeof data !== "object") throw new InputError("INVALID_REQUEST");
  const type = data.type as SourceType;
  if (!Object.hasOwn(LIMITS, type)) throw new InputError("UNSUPPORTED_TYPE");
  const mime = str(data.mime, "MIME", 80);
  const allowed = {image: ["image/jpeg", "image/png"], pdf: ["application/pdf"], audio: ["audio/mp4"], note: ["text/plain"]};
  if (!allowed[type].includes(mime)) throw new InputError("UNSUPPORTED_TYPE");
  const c = data.context || {};
  if (!["spring", "fall"].includes(c.semester)) throw new InputError("INVALID_SEMESTER");
  const text = type === "note" ? str(data.text, "TEXT", 20000) : undefined;
  const size = type === "note" ? Buffer.byteLength(text!) : integer(data.size, "SIZE", 1, LIMITS[type]);
  if (size > LIMITS[type]) throw new InputError("QUOTA_EXCEEDED");
  return {
    clientRequestId: id(data.clientRequestId), type, title: str(data.title, "TITLE"), size, mime,
    ...(text ? {text} : {}),
    ...(type === "audio" ? {durationSeconds: integer(data.durationSeconds, "DURATION", 1, 5400)} : {}),
    context: {
      ...(c.classDocId ? {classDocId: str(c.classDocId, "CLASS", 300)} : {}),
      localCourseId: c.localCourseUUID ? str(c.localCourseUUID, "COURSE_UUID", 36) : str(c.localCourseId, "COURSE", 300),
      ...(c.localCourseUUID ? {localCourseUUID: str(c.localCourseUUID, "COURSE_UUID", 36)} : {}),
      ...(c.year !== undefined && c.year !== null ? {year: integer(c.year, "YEAR", 2000, 2100)} : {}), semester: c.semester,
      ...(c.syllabusUrl !== undefined ? {syllabusUrl: optionalText(c.syllabusUrl, 2000)} : {}),
      ...(c.courseName !== undefined ? {courseName: optionalText(c.courseName, 200)} : {}),
      ...(c.teacherName !== undefined ? {teacherName: optionalText(c.teacherName, 200)} : {}),
      dayID: integer(c.dayID, "DAY", 10000, 50000), occurrenceKey: c.occurrenceKey ? id(c.occurrenceKey) : "default"
    }
  };
}
function optionalText(value: unknown, max: number): string {
  if (value === null) return "";
  if (typeof value !== "string" || value.length > max) throw new InputError("INVALID_COURSE_METADATA");
  return value.trim();
}
export function canRead(source: any, uid: string, verified: boolean, raw = false): boolean {
  return !["deleting", "deleted"].includes(source.status) &&
    (source.ownerUserId === uid || (verified && (raw ? source.rawVisibility : source.knowledgeVisibility) === "course"));
}
export function mayPublish(source: any, token: string): boolean {
  return source?.leaseToken === token && ["extracting", "indexing"].includes(source.status);
}
export function chunksFor(units: Unit[]): Chunk[] {
  const chunks: Chunk[] = [];
  for (const unit of units) {
    for (let start = 0; start < unit.text.length; start += 1300) {
      const end = Math.min(start + 1500, unit.text.length);
      chunks.push({...unit, text: unit.text.slice(start, end), chunkId: String(chunks.length).padStart(6, "0"),
        locator: unit.method === "note" ? {...unit.locator, startChar: start, endChar: end} : unit.locator});
      if (end === unit.text.length) break;
    }
  }
  if (chunks.length > 800) throw new InputError("TOO_MUCH_TEXT");
  return chunks;
}
export function weekKey(now: Date): string {
  const d = new Date(now.getTime() + 9 * 3600000);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}
export function lexicalScore(text: string, query: string): number {
  const terms = [...new Intl.Segmenter("ja", {granularity: "word"}).segment(query.normalize("NFKC").toLowerCase())]
    .filter(p => p.isWordLike).map(p => p.segment);
  const haystack = text.normalize("NFKC").toLowerCase();
  return [...new Set(terms)].reduce((score, term) => score + (haystack.includes(term) ? 1 : 0), 0);
}
export function selectContext<T extends {text: string; sourceId: string}>(items: T[], purpose: string, query: string, maxChars: number) {
  let ordered: T[];
  if (purpose === "question") {
    ordered = items.map(item => ({item, score: lexicalScore(item.text, query)}))
      .filter(x => x.score > 0).sort((a, b) => b.score - a.score).map(x => x.item);
  } else {
    // Round-robin prevents the first long source from consuming the entire budget.
    const groups = new Map<string, T[]>();
    for (const item of items) groups.set(item.sourceId, [...(groups.get(item.sourceId) || []), item]);
    ordered = [];
    while ([...groups.values()].some(g => g.length)) for (const g of groups.values()) if (g.length) ordered.push(g.shift()!);
  }
  const selected: T[] = [];
  let used = 0;
  for (const item of ordered) {
    if (used + item.text.length > maxChars) continue;
    selected.push(item); used += item.text.length;
  }
  return {items: selected, truncated: selected.length < ordered.length};
}
