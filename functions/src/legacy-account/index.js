// Extracted from deployed aad2425fe638; only account-deletion exports, never import/wipe/search functions.
const {onCall,HttpsError}=require('firebase-functions/v2/https');
const functionsV1=require('firebase-functions/v1');
const {defineString}=require('firebase-functions/params');
const admin=require('firebase-admin');
const {finishAIAccountDeletion}=require('../ai/account-deletion');
const {defaultDatabase}=require('../ai/databases');
if(!admin.apps.length)admin.initializeApp();
const accountRuntime=defineString('AI_ACCOUNT_DELETION_SERVICE_ACCOUNT');
const options={region:'asia-northeast1',memory:'1GiB',timeoutSeconds:540,cpu:'gcf_gen1',maxInstances:20,serviceAccount:accountRuntime};
function requireRecentAuth(auth) {
  const age=Date.now()/1000-Number(auth.token&&auth.token.auth_time);
  if(!Number.isFinite(age)||age<0||age>300)throw new HttpsError('failed-precondition','Reauthenticate before deleting the account',{code:'REAUTH_REQUIRED'});
}
// 共通: Query の結果を BulkWriter で一括削除
async function _deleteByQuery(q) {
  const snap = await q.get();
  if (snap.empty) return;
  const writer = defaultDatabase().bulkWriter();
  for (const d of snap.docs) writer.delete(d.ref);
  await writer.close();
}

// 共通: collectionGroup で docId == uid を根こそぎ削除
async function _deleteCollectionGroupByDocId(groupName, uid) {
  const q = defaultDatabase().collectionGroup(groupName)
    .where(admin.firestore.FieldPath.documentId(), '==', uid);
  await _deleteByQuery(q);
}

async function _deleteCollectionGroupWhere(groupName, field, uid) {
  try {
    const q = defaultDatabase().collectionGroup(groupName).where(field, '==', uid);
    await _deleteByQuery(q);
  } catch (e) {
    // インデックス未作成など → スキップして続行（ログは残す）
    if (e?.code === 9 || String(e?.message || '').includes('FAILED_PRECONDITION')) {
      console.warn(`[cleanup] skip group=${groupName} field=${field} : ${e.message}`);
      return;
    }
    throw e; // それ以外は従来通り投げる
  }
}

// 友だち・申請の相手側リンク掃除（ID型はフィールドでカバー）
async function _cleanupCrossUserLinks(uid) {
  const targets = [
    // 友だち（自分が friendUid として相手側に載っている）
    { group: 'friends',          field: 'friendUid' },
    { group: 'Friends',          field: 'friendUid' },  // 大小混在対策

    // 受信箱（相手側のリクエストに自分が senderUid として載っている）
    { group: 'requestsIncoming', field: 'senderUid' },
    { group: 'requestIncoming',  field: 'senderUid' },
    { group: 'incomingRequests', field: 'senderUid' },

    // 送信箱（相手側のリクエストに自分が targetUid として載っている）
    { group: 'requestsOutgoing', field: 'targetUid' },
    { group: 'requestOutgoing',  field: 'targetUid' },
    { group: 'outgoingRequests', field: 'targetUid' },
  ];

  for (const t of targets) {
    await _deleteCollectionGroupWhere(t.group, t.field, uid);
  }
}

// Storage バケットを安全に取得（未設定でも落ちない）
function getBucketSafeForCleanup() {
  try {
    const opt = admin.app().options || {};
    if (opt.storageBucket) return admin.storage().bucket(opt.storageBucket);
    return admin.storage().bucket();
  } catch (e) {
    console.warn('Storage bucket is not configured. Skipping avatar deletion.', e.message);
    return null;
  }
}

// アイコン画像の削除（avatars/{uid}.jpg と avatars/{uid}/ 以下）
async function _deleteAvatarFiles(uid) {
  const bucket = getBucketSafeForCleanup();
  if (!bucket) return;

  await bucket.file(`avatars/${uid}.jpg`).delete({ ignoreNotFound: true }).catch(() => {});
  const [files] = await bucket.getFiles({ prefix: `avatars/${uid}/` }).catch(() => [null]);
  if (Array.isArray(files)) {
    await Promise.all(files.map(f => f.delete({ ignoreNotFound: true }).catch(() => {})));
  }
}

// usernames の削除（users/{uid} の idLower 等を参照）
async function _deleteUsernameMapping(uid, displayName) {
  const doc = await defaultDatabase().collection('users').doc(uid).get();
  const data = doc.exists ? (doc.data() || {}) : {};
  const key =
    data.idLower ||
    data.usernameLower ||
    (typeof data.id === 'string' ? data.id.toLowerCase() : undefined) ||
    (typeof displayName === 'string' ? displayName.toLowerCase() : undefined);
  if (key) {
    await defaultDatabase().collection('usernames').doc(String(key)).delete().catch(() => {});
  }
}

// 自分ツリー（users/{uid} 配下 & 自分doc）を削除
async function _deleteUserTree(uid) {
  const subs = [
    'timetable',
    'Friends', 'friends',
    'requestsIncoming', 'requestIncoming', 'incomingRequests',
    'requestsOutgoing', 'requestOutgoing', 'outgoingRequests',
  ];
  for (const s of subs) {
    const q = defaultDatabase().collection('users').doc(uid).collection(s);
    const snap = await q.get();
    if (!snap.empty) {
      const writer = defaultDatabase().bulkWriter();
      for (const d of snap.docs) writer.delete(d.ref);
      await writer.close();
    }
  }
  await defaultDatabase().recursiveDelete(defaultDatabase().collection('users').doc(uid));
  await defaultDatabase().recursiveDelete(defaultDatabase().collection('privateUsage').doc(uid));
  const bucket=getBucketSafeForCleanup();
  if(bucket) { const [files]=await bucket.getFiles({prefix:`users/${uid}/transcriptionUploads/`}); await Promise.all(files.map(f=>f.delete({ignoreNotFound:true}))); }
}

// 事前掃除（必要ならクライアントから呼ぶ）
exports.preDeleteCleanup = onCall(options, async (request) => {
  const { data, auth } = request;
  if (!auth || !auth.uid) throw new HttpsError('unauthenticated', 'Sign-in required');
  const caller = auth.uid;
  const uid = (data && data.uid) || caller;
  if (uid !== caller) throw new HttpsError('permission-denied', 'Cannot clean up other users');
  requireRecentAuth(auth);

  try {
    await finishAIAccountDeletion(uid);
    await defaultDatabase().recursiveDelete(defaultDatabase().collection('privateUsage').doc(uid));
    await _cleanupCrossUserLinks(uid);
    await _deleteAvatarFiles(uid);
    await _deleteUsernameMapping(uid, auth.token && auth.token.name);
    return { ok: true, aiAccountDeletionVersion: 1 };
  } catch (e) {
    console.error('preDeleteCleanup failed:', uid, e);
    throw new HttpsError('internal', e.message || 'internal-error', { code: e.code, stack: e.stack });
  }
});

// Auth 削除後の最終掃除（v1 trigger, リージョン固定）
exports.onAuthUserDelete = functionsV1
  .region('asia-northeast1')
  .runWith({serviceAccount:accountRuntime,memory:"512MB",timeoutSeconds:540,maxInstances:20})
  .auth.user()
  .onDelete(async (user) => {
    const uid = user.uid;
    await finishAIAccountDeletion(uid);
    await _cleanupCrossUserLinks(uid);
    await _deleteAvatarFiles(uid);
    await _deleteUsernameMapping(uid, user.displayName || undefined);
    await _deleteUserTree(uid);
  });

// 代表的なサーバサイド削除（段階ログ付き）
exports.deleteAccountServerSide = onCall(options, async (request) => {
  const { auth } = request;
  if (!auth || !auth.uid) throw new HttpsError('unauthenticated', 'Sign-in required');
  const uid = auth.uid;

  // どこで落ちたかを特定するための段階ログ
  const step = (n, msg) => console.log(`[DEL ${uid}] #${n} ${msg}`);

  try {
    requireRecentAuth(auth);
    step(1, 'start');
    await finishAIAccountDeletion(uid);

    // 1) 相手側リンク掃除（friends / requests…）
    try {
      step(2, 'cleanup cross links');
      await _cleanupCrossUserLinks(uid);
    } catch (e) {
      console.error(`[DEL ${uid}] cross-links failed`, e);
      throw new HttpsError('internal', 'cross-links failed', { where: 'crossLinks', message: e.message, code: e.code });
    }

    // 2) アバター削除（Storage 未設定でもスキップする実装になっています）
    try {
      step(3, 'delete avatar files');
      await _deleteAvatarFiles(uid);
    } catch (e) {
      console.error(`[DEL ${uid}] avatar delete failed`, e);
      throw new HttpsError('internal', 'avatar delete failed', { where: 'avatar', message: e.message, code: e.code });
    }

    // 3) usernames 対応表の削除
    try {
      step(4, 'delete username mapping');
      await _deleteUsernameMapping(uid, auth.token && auth.token.name);
    } catch (e) {
      console.error(`[DEL ${uid}] username mapping failed`, e);
      throw new HttpsError('internal', 'username mapping failed', { where: 'usernames', message: e.message, code: e.code });
    }

    // 4) Auth ユーザー本体の削除
    try {
      step(5, 'admin.auth().deleteUser');
      await admin.auth().deleteUser(uid);
    } catch (e) {
      console.error(`[DEL ${uid}] auth.delete failed`, e);
      // 代表例: auth/user-not-found など
      throw new HttpsError('internal', 'auth delete failed', { where: 'auth', message: e.message, code: e.code });
    }

    await _deleteUserTree(uid);
    step(6, 'done');
    return { ok: true };
  } catch (e) {
    // ここに来ると iOS 側の FunctionsErrorDetailsKey に {where, message, code} が入る
    console.error(`[DEL ${uid}] FAILED`, e);
    if (e instanceof HttpsError) throw e;
    throw new HttpsError('internal', e.message || 'internal-error', { where: 'unknown', message: e.message, code: e.code, stack: e.stack });
  }
});
