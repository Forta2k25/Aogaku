// Dedicated production entry for the chat reply function only. Kept separate from production.ts (exactly twelve
// verified AI exports) so the existing rollout artifacts and guards are untouched. Deployed as its own codebase.
import * as admin from "firebase-admin";
import * as ai from "./ai";
if (!admin.apps.length) admin.initializeApp();
export const aiChat = ai.aiChat;
