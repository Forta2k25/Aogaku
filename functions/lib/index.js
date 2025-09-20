"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.onIncomingRequestDeleted = exports.onFriendshipCreated = exports.onIncomingRequest = void 0;
const functions = __importStar(require("firebase-functions/v1"));
const admin = __importStar(require("firebase-admin"));
admin.initializeApp();
const db = admin.firestore();
const region = "asia-northeast1";
/** 指定ユーザーの iOS FCM トークン一覧を取得 */
async function getUserTokens(uid) {
    const snap = await db.collection("users").doc(uid).collection("fcmTokens").get();
    return snap.docs.map((d) => d.id);
}
/** マルチキャスト送信（無効トークンは掃除） */
async function sendTo(uid, title, body, data = {}) {
    const tokens = await getUserTokens(uid);
    if (tokens.length === 0)
        return;
    const res = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: { title, body },
        data,
        apns: { payload: { aps: { sound: "default", badge: 1 } } },
    });
    const invalid = [];
    res.responses.forEach((r, i) => {
        if (!r.success) {
            const code = r.error?.errorInfo?.code || "";
            if (code === "messaging/registration-token-not-registered") {
                invalid.push(tokens[i]); // ← 明示キャストで型エラー回避
            }
        }
    });
    await Promise.all(invalid.map((t) => db
        .collection("users")
        .doc(uid)
        .collection("fcmTokens")
        .doc(t)
        .delete()
        .catch(() => { })));
    console.log("sendTo", uid, "tokens", tokens.length, "success", res.successCount, "failure", res.failureCount);
    res.responses.forEach((r, i) => {
        if (!r.success) {
            console.error("send error token:", tokens[i], "msg:", r.error?.message);
        }
    });
}
/** 友だち申請が届いたとき：users/{target}/requestsIncoming/{from} 追加で通知 */
exports.onIncomingRequest = functions
    .region(region)
    .firestore.document("users/{targetUid}/requestsIncoming/{fromUid}")
    .onCreate(async (_snap, ctx) => {
    const { targetUid, fromUid } = ctx.params;
    const fromDoc = await db.collection("users").doc(fromUid).get();
    const name = fromDoc.get("name") || ("@" + (fromDoc.get("id") || "user"));
    await sendTo(targetUid, "友だち申請が届きました", `${name} から友だち申請が来ています。`, { screen: "friend_requests" });
});
// 承認通知（リクエスト送信者に送る）※既存の onFriendshipCreated をこの実装で置き換え
// 既存の import と初期化はそのまま（admin.initializeApp() など）:contentReference[oaicite:0]{index=0}
exports.onFriendshipCreated = functions
    .region(region) // asia-northeast1 のまま:contentReference[oaicite:1]{index=1}
    .firestore.document("users/{uid}/friends/{friendUid}")
    .onCreate(async (_snap, ctx) => {
    const { uid, friendUid } = ctx.params;
    // 友だちペアごとの一回きり通知フラグ
    const pair = [uid, friendUid].sort().join("_");
    const flagRef = db.collection("meta")
        .doc("notificationFlags")
        .collection("friendAccepted")
        .doc(pair);
    if ((await flagRef.get()).exists) {
        console.log("onFriendshipCreated: already notified for", pair);
        return;
    }
    // 承認者=このドキュメント側(uid) の表示名
    const approverDoc = await db.doc(`users/${uid}`).get();
    const name = approverDoc.get("name") ||
        ("@" + (approverDoc.get("id") || "user"));
    // 相手（friendUid）にだけ通知する
    await sendTo(friendUid, "友だち申請が承認されました", `${name} があなたの申請を承認しました。`, { screen: "friends_list" });
    await flagRef.set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
});
// 承認時の保険：requestsIncoming の削除を検知して、友だち成立なら申請者に通知
exports.onIncomingRequestDeleted = functions
    .region(region)
    .firestore.document("users/{uid}/requestsIncoming/{fromUid}")
    .onDelete(async (_snap, ctx) => {
    const { uid, fromUid } = ctx.params;
    // 削除が「拒否」ではなく「承認」によるものかを判定：どちらかの friends が存在すれば承認とみなす
    const [a, b] = await Promise.all([
        db.doc(`users/${uid}/friends/${fromUid}`).get(),
        db.doc(`users/${fromUid}/friends/${uid}`).get(),
    ]);
    if (!a.exists && !b.exists) {
        console.log("request deleted but no friendship -> decline/cancel", uid, fromUid);
        return;
    }
    // ペアごと一度だけ通知（既存の onFriendshipCreated と共通のフラグを使用）
    const pair = [uid, fromUid].sort().join("_");
    const flagRef = db.collection("meta").doc("notificationFlags").collection("friendAccepted").doc(pair);
    if ((await flagRef.get()).exists) {
        console.log("already notified for", pair);
        return;
    }
    // 承認者(uid)の名前で、申請者(fromUid)に通知
    const approverDoc = await db.doc(`users/${uid}`).get();
    const name = approverDoc.get("name") || ("@" + (approverDoc.get("id") || "user"));
    await sendTo(fromUid, "友だち申請が承認されました", `${name} があなたの申請を承認しました。`, { screen: "friends_list" });
    await flagRef.set({ createdAt: admin.firestore.FieldValue.serverTimestamp(), by: "onIncomingRequestDeleted" });
});
