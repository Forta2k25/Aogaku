// 会話の履歴(文章だけ)を、アプリとWebで同期するための、入力の検証。
// 保存先: aiChats/{uid}/offerings/{courseOfferingId}/messages/{messageId}(アカウント削除で、aiChats/{uid} ごと消す)。
// 写真・録音・PDFの原本は、ここには置かない(資料として、すでにサーバーにある)。会話には「画像を送った」ことだけを残す。
import {InputError, id, integer} from "./domain";

export const CONVERSATION = Object.freeze({maxBatch: 50, maxText: 20000, maxList: 200, maxDelete: 100, maxImages: 20});
export type ConversationRole = "user" | "assistant";
export type ConversationKind = "text" | "image" | "audio" | "pdf" | "note";
export interface ConversationMessage {
  id: string; role: ConversationRole; kind: ConversationKind; text: string; imageCount: number; createdAt: number;
}
const roles: ConversationRole[] = ["user", "assistant"];
const kinds: ConversationKind[] = ["text", "image", "audio", "pdf", "note"];

/** 保存する発言の検証。文章の本文だけを受け取る(写真などの中身は受け取らない)。 */
export function validateMessages(data: any, now = Date.now()): ConversationMessage[] {
  const rows = data?.messages;
  if (!Array.isArray(rows) || rows.length < 1 || rows.length > CONVERSATION.maxBatch) throw new InputError("INVALID_MESSAGES");
  const seen = new Set<string>();
  return rows.map(row => {
    if (!row || typeof row !== "object") throw new InputError("INVALID_MESSAGES");
    const messageId = id(row.id);
    if (seen.has(messageId)) throw new InputError("DUPLICATE_MESSAGE");
    seen.add(messageId);
    const role = row.role as ConversationRole, kind = (row.kind ?? "text") as ConversationKind;
    if (!roles.includes(role) || !kinds.includes(kind)) throw new InputError("INVALID_MESSAGES");
    if (typeof row.text !== "string" || row.text.length > CONVERSATION.maxText) throw new InputError("INVALID_MESSAGES");
    const text = row.text.trim();
    // 文章の発言は、空にできない。画像などの発言は、本文なしで、種類だけを残す。
    if (kind === "text" && !text) throw new InputError("INVALID_MESSAGES");
    const createdAt = integer(row.createdAt, "CREATED_AT", 1_000_000_000_000, now + 86_400_000);
    const imageCount = row.imageCount === undefined ? (kind === "image" ? 1 : 0) : integer(row.imageCount, "IMAGE_COUNT", 0, CONVERSATION.maxImages);
    return {id: messageId, role, kind, text, imageCount, createdAt};
  });
}

export function validateDeleteIds(data: any): string[] {
  const ids = data?.ids;
  if (!Array.isArray(ids) || ids.length < 1 || ids.length > CONVERSATION.maxDelete) throw new InputError("INVALID_MESSAGES");
  return [...new Set(ids.map(value => id(value)))];
}

export function validateListCursor(data: any): number | undefined {
  if (data?.after === undefined || data.after === null) return undefined;
  return integer(data.after, "CURSOR", 0, Number.MAX_SAFE_INTEGER);
}
