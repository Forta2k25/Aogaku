import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";
admin.initializeApp();

const db = admin.firestore();
const region = "asia-northeast1";

/** 指定ユーザーの iOS FCM トークン一覧を取得 */
async function getUserTokens(uid: string): Promise<string[]> {
  const snap = await db.collection("users").doc(uid).collection("fcmTokens").get();
  return snap.docs.map((d) => d.id);
}

/** マルチキャスト送信（無効トークンは掃除） */
async function sendTo(
  uid: string,
  title: string,
  body: string,
  data: Record<string, string> = {}
) {
  const tokens: string[] = await getUserTokens(uid);
  if (tokens.length === 0) return;

  const res = await admin.messaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    data,
    apns: { payload: { aps: { sound: "default", badge: 1 } } },
  });

  const invalid: string[] = [];
  res.responses.forEach((r, i) => {
    if (!r.success) {
      const code: string = ((r.error as any)?.errorInfo?.code as string) || "";
      if (code === "messaging/registration-token-not-registered") {
        invalid.push(tokens[i] as string); // ← 明示キャストで型エラー回避
      }
    }
  });

  await Promise.all(
    invalid.map((t) =>
      db
        .collection("users")
        .doc(uid)
        .collection("fcmTokens")
        .doc(t)
        .delete()
        .catch(() => { })
    )
  );

  console.log("sendTo", uid, "tokens", tokens.length,
    "success", res.successCount, "failure", res.failureCount);
  res.responses.forEach((r, i) => {
    if (!r.success) {
      console.error("send error token:", tokens[i], "msg:", r.error?.message);
    }
  });
}

/** 友だち申請が届いたとき：users/{target}/requestsIncoming/{from} 追加で通知 */
export const onIncomingRequest = functions
  .region(region)
  .firestore.document("users/{targetUid}/requestsIncoming/{fromUid}")
  .onCreate(async (_snap: functions.firestore.DocumentSnapshot, ctx: functions.EventContext) => {
    const { targetUid, fromUid } = ctx.params as { targetUid: string; fromUid: string };
    const fromDoc = await db.collection("users").doc(fromUid).get();
    const name: string =
      (fromDoc.get("name") as string) || ("@" + ((fromDoc.get("id") as string) || "user"));
    await sendTo(
      targetUid,
      "友だち申請が届きました",
      `${name} から友だち申請が来ています。`,
      { screen: "friend_requests" }
    );
  });

// 承認通知（リクエスト送信者に送る）※既存の onFriendshipCreated をこの実装で置き換え
// 既存の import と初期化はそのまま（admin.initializeApp() など）:contentReference[oaicite:0]{index=0}

export const onFriendshipCreated = functions
  .region(region) // asia-northeast1 のまま:contentReference[oaicite:1]{index=1}
  .firestore.document("users/{uid}/friends/{friendUid}")
  .onCreate(async (_snap, ctx) => {
    const { uid, friendUid } = ctx.params as { uid: string; friendUid: string };

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
    const name =
      (approverDoc.get("name") as string) ||
      ("@" + ((approverDoc.get("id") as string) || "user"));

    // 相手（friendUid）にだけ通知する
    await sendTo(
      friendUid,
      "友だち申請が承認されました",
      `${name} があなたの申請を承認しました。`,
      { screen: "friends_list" }
    );

    await flagRef.set({ createdAt: admin.firestore.FieldValue.serverTimestamp() });
  });

// 承認時の保険：requestsIncoming の削除を検知して、友だち成立なら申請者に通知
export const onIncomingRequestDeleted = functions
  .region(region)
  .firestore.document("users/{uid}/requestsIncoming/{fromUid}")
  .onDelete(async (_snap, ctx) => {
    const { uid, fromUid } = ctx.params as { uid: string; fromUid: string };

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
    const name =
      (approverDoc.get("name") as string) || ("@" + ((approverDoc.get("id") as string) || "user"));

    await sendTo(
      fromUid,
      "友だち申請が承認されました",
      `${name} があなたの申請を承認しました。`,
      { screen: "friends_list" }
    );

    await flagRef.set({ createdAt: admin.firestore.FieldValue.serverTimestamp(), by: "onIncomingRequestDeleted" });
  });


