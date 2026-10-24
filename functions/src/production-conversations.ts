// 会話の履歴の同期(アプリ ⇄ Web)の3関数だけを、本番へ出すための入口。aiChat と同じく、独立したコードベースとして公開する。
// production.ts(ちょうど12個のAI関数)と production-chat.ts には、触れない。
import * as admin from "firebase-admin";
import * as ai from "./ai";
if (!admin.apps.length) admin.initializeApp();
export const aiSaveMessages = ai.aiSaveMessages;
export const aiListMessages = ai.aiListMessages;
export const aiDeleteMessages = ai.aiDeleteMessages;
