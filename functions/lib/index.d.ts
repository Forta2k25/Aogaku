import * as functions from "firebase-functions/v1";
/** 友だち申請が届いたとき：users/{target}/requestsIncoming/{from} 追加で通知 */
export declare const onIncomingRequest: functions.CloudFunction<functions.firestore.QueryDocumentSnapshot>;
/** 申請が承認されたとき：users/{uid}/friends/{friendUid} 追加で通知 */
export declare const onFriendshipCreated: functions.CloudFunction<functions.firestore.QueryDocumentSnapshot>;
//# sourceMappingURL=index.d.ts.map