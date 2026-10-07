// functions/index.js — Firebase Functions (v2 HTTP/Callable + v1 Auth trigger)

// -------------------- Imports --------------------
const { onRequest, onCall, HttpsError } = require('firebase-functions/v2/https');
const { setGlobalOptions } = require('firebase-functions/v2/options');
const admin = require('firebase-admin');
const functionsV1 = require('firebase-functions'); // v1 の Auth トリガ用
const crypto = require('crypto');

// -------------------- Init --------------------
if (!admin.apps.length) admin.initializeApp();
setGlobalOptions({ region: 'asia-northeast1', memory: '1GiB', timeoutSeconds: 540, secrets: ['IMPORT_API_KEY'] });

const db = admin.firestore();
const API_KEY = process.env.IMPORT_API_KEY || 'DEV_ONLY_FALLBACK';

// ===================================================================
// helpers
// ===================================================================
function normalize(s = "") {
  return String(s).toLowerCase().replace(/\u3000/g, " ").replace(/\s+/g, "");
}
function ngrams2(s = "") {
  const t = normalize(s);
  const out = [];
  for (let i = 0; i <= t.length - 2; i++) out.push(t.slice(i, i + 2));
  if (out.length === 0 && t) out.push(t);
  return Array.from(new Set(out));
}
function parseTime(timeStr) {
  if (!timeStr) return { day: null, periods: [] };
  const s = String(timeStr).normalize('NFKC').replace(/\s+/g, '');
  if (!s || /集中|随時|未定|tba/i.test(s)) return { day: null, periods: [] };
  const m = s.match(/[月火水木金土日]/);
  const day = m ? m[0] : null;
  const tail = day ? s.slice(s.indexOf(day) + 1) : s;
  const normalized = tail.replace(/[・/／，]/g, ',');
  let periods = [];
  for (const part of normalized.split(',').filter(Boolean)) {
    if (part.includes('-')) {
      const [a, b] = part.split('-').map(n => parseInt(n, 10));
      if (!isNaN(a) && !isNaN(b) && a <= b) for (let p = a; p <= b; p++) periods.push(p);
    } else {
      const n = parseInt(part, 10);
      if (!isNaN(n)) periods.push(n);
    }
  }
  return { day, periods: Array.from(new Set(periods)).sort((x, y) => x - y) };
}
function makeDocId(code, key) {
  return /^[0-9A-Za-z._-]{3,}$/.test(code || '')
    ? `c_${code}`
    : crypto.createHash('sha1').update(key || '').digest('hex').slice(0, 20);
}
function yyyymmddHHMM() {
  const d = new Date();
  const z = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}${z(d.getMonth()+1)}${z(d.getDate())}${z(d.getHours())}${z(d.getMinutes())}`;
}
// Storage バケットを安全に取得（未設定でも落ちない）
function getBucketSafe() {
  try {
    const opt = admin.app().options || {};
    if (opt.storageBucket) return admin.storage().bucket(opt.storageBucket);
    return admin.storage().bucket();
  } catch (e) {
    console.warn('Storage bucket is not configured. Skipping avatar / index ops.', e.message);
    return null;
  }
}

// ===================================================================
// Import classes (HTTP)
// ===================================================================
exports.importClasses = onRequest(async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');
  if (req.method === 'OPTIONS') return res.status(204).send('');

  try {
    if (req.method !== 'POST') return res.status(405).send('POST only');
    if (req.get('x-api-key') !== API_KEY) return res.status(403).send('forbidden');

    const rows = Array.isArray(req.body?.rows) ? req.body.rows : [];
    if (rows.length === 0) return res.status(400).send('rows[] required');

    let written = 0;
    for (let i = 0; i < rows.length; i += 400) {
      const batch = db.batch();

      rows.slice(i, i + 400).forEach(r => {
        const code     = String(r['登録番号'] || '').trim();
        const campus   = String(r['キャンパス'] || '').trim();
        const timeStr  = String(r['時限'] || '').trim();
        const term     = String(r['期間'] || '').trim();
        const name     = String(r['科目名'] || '').trim();
        const teacher  = String(r['教師'] || '').trim();
        const room     = String(r['教室'] || '').trim();
        const credit   = Number(r['単位']);
        const category = String(r['分類'] || '').trim();
        const grade    = String(r['学年'] || '').trim();
        const message  = String(r['メッセージ'] || '').trim();
        const url      = String(r['URL'] || '').trim();

        // ★ 追記: 成績評価（あれば取り込む。空はスキップ＝既存値を温存）
        const evalMethod = String(
          r['成績評価方法'] || r['成績評価'] || r['評価方法'] ||
          r['evaluation'] || r['evaluation_method'] || ''
        ).trim();
        const evalNote = String(
          r['成績評価メモ'] || r['評価メモ'] || r['evaluation_note'] || ''
        ).trim();

        const { day, periods } = parseTime(timeStr);
        // ★ __id が送られてきていればそれを優先（5桁ゼロ埋めを想定）
        const incomingId = r.__id ? String(r.__id).padStart(5, '0') : null;
        const fallbackId = makeDocId(code, `${name}|${teacher}|${campus}|${timeStr}`);
        const docId = incomingId || fallbackId;
        const base = [name, teacher, campus, category].join(' '); // 検索用

const payload = {
          class_name: name,
          teacher_name: teacher,
          campus,
          category,
          credit: Number.isFinite(credit) ? credit : 0,
          grade,
          time: { day: day || null, periods },
          code,
          term,
          room,
          message,
          url,
          ngrams2: ngrams2(base),
        };
        // ★ 追記: 値があればのみ書き込む（空文字で既存値を消さない）
        if (evalMethod) payload.eval_method = evalMethod;
        if (evalNote)   payload.eval_note   = evalNote;

        // 直前までのコードはあなたのまま（payload を組み立て済み）
        const ref = db.collection('classes').doc(docId);

        // ここを差し替え：payload をそのまま merge 書き込み
        batch.set(ref, payload, { merge: true });


      });

      await batch.commit();
      written += Math.min(400, rows.length - i);
    }

    res.json({ ok: true, count: written });
  } catch (e) {
    console.error(e);
    res.status(500).send(String(e));
  }
});

// ===================================================================
// Wipe classes (HTTP)
// ===================================================================
exports.wipeClasses = onRequest(async (req, res) => {
  if (req.get('x-api-key') !== API_KEY) return res.status(403).send('forbidden');
  let deleted = 0;
  while (true) {
    const snap = await db.collection('classes').limit(400).get();
    if (snap.empty) break;
    const b = db.batch();
    snap.docs.forEach(d => b.delete(d.ref));
    await b.commit();
    deleted += snap.size;
  }
  res.json({ ok: true, deleted });
});

// ===================================================================
// Reindex classes (HTTP)
// ===================================================================
exports.reindexClasses = onRequest(async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(204).send('');

  try {
    const col = db.collection('classes');
    let last = null;
    let updated = 0;

    while (true) {
      let q = col.orderBy('__name__').limit(500);
      if (last) q = q.startAfter(last);
      const snap = await q.get();
      if (snap.empty) break;

      const batch = db.batch();
      snap.docs.forEach((doc) => {
        const x = doc.data() || {};
        const base = [x.class_name || '', x.teacher_name || '', x.campus || '', x.category || ''].join(' ');
        batch.update(doc.ref, { ngrams2: ngrams2(base) });
      });
      await batch.commit();

      updated += snap.size;
      last = snap.docs[snap.docs.length - 1];
    }

    return res.json({ ok: true, updated });
  } catch (e) {
    console.error(e);
    return res.status(500).send(String(e));
  }
});

// ===================================================================
// Build syllabus index JSON (HTTP)  ←★ 新規
// ===================================================================
exports.buildSyllabusIndex = onRequest(async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');
  if (req.method === 'OPTIONS') return res.status(204).send('');

  try {
    if (req.method !== 'POST') return res.status(405).send('POST only');
    if (req.get('x-api-key') !== API_KEY) return res.status(403).send('forbidden');

    // version 指定があれば使う（例: "2025-10-10-1"）。なければ yyyymmddHHMM
    const version = String(req.body?.version || yyyymmddHHMM());

    // classes 全件を軽量配列にする
    const out = [];
    const col = db.collection('classes');
    let last = null;
    while (true) {
      let q = col.orderBy('__name__').limit(1000);
      if (last) q = q.startAfter(last);
      const snap = await q.get();
      if (snap.empty) break;

      for (const doc of snap.docs) {
        const x = doc.data() || {};
        const campus = Array.isArray(x.campus)
          ? x.campus.filter(Boolean)
          : (x.campus ? [x.campus] : []);
        const periods = Array.isArray(x?.time?.periods)
          ? Array.from(new Set(x.time.periods)).sort((a,b)=>a-b)
          : [];
        out.push({
          id: doc.id,
          class_name: String(x.class_name || ''),
          teacher_name: String(x.teacher_name || ''),
          category: String(x.category || ''),
          grade: String(x.grade || ''),
          campus,
          time: { day: x?.time?.day || null, periods },
          term: String(x.term || ''),
          credit: Number.isFinite(x.credit) ? Number(x.credit) : 0,
        });
      }
      last = snap.docs[snap.docs.length - 1];
    }

    // Storage に保存（token 付き URL を発行して誰でもDL可能に）
    const bucket = getBucketSafe();
    if (!bucket) return res.status(500).send('storage bucket not configured');

    const fname = `syllabus/syllabus_index_v${version}.json`;
    const token = crypto.randomUUID();
    await bucket.file(fname).save(Buffer.from(JSON.stringify(out)), {
      contentType: 'application/json; charset=utf-8',
      metadata: { metadata: { firebaseStorageDownloadTokens: token } },
      resumable: false,
      // ほどよいキャッシュ（5分）
      cacheControl: 'public, max-age=300, s-maxage=300',
    });

    const publicUrl =
      `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
      `${encodeURIComponent(fname)}?alt=media&token=${token}`;

    // Remote Config を自動更新（失敗しても成功レスは返す）
    let rcUpdated = false;
    try {
      const rc = admin.remoteConfig();
      const tpl = await rc.getTemplate();
      tpl.parameters = tpl.parameters || {};
      tpl.parameters['syllabusIndexURL'] = { defaultValue: { value: publicUrl } };
      tpl.parameters['syllabusIndexVersion'] = { defaultValue: { value: version } };
      await rc.publishTemplate(tpl);
      rcUpdated = true;
    } catch (e) {
      console.warn('[buildSyllabusIndex] remoteConfig publish failed:', e.message);
    }

    return res.json({
      ok: true,
      count: out.length,
      bucket: bucket.name,
      object: fname,
      version,
      url: publicUrl,
      remoteConfigUpdated: rcUpdated,
    });
  } catch (e) {
    console.error(e);
    return res.status(500).send(String(e));
  }
});

// ===================================================================
// Account Deletion Cleanup (Callable + Auth Trigger)
// ===================================================================

// 共通: Query の結果を BulkWriter で一括削除
async function _deleteByQuery(q) {
  const snap = await q.get();
  if (snap.empty) return;
  const writer = admin.firestore().bulkWriter();
  for (const d of snap.docs) writer.delete(d.ref);
  await writer.close();
}

// 共通: collectionGroup で docId == uid を根こそぎ削除
async function _deleteCollectionGroupByDocId(groupName, uid) {
  const q = admin.firestore().collectionGroup(groupName)
    .where(admin.firestore.FieldPath.documentId(), '==', uid);
  await _deleteByQuery(q);
}

async function _deleteCollectionGroupWhere(groupName, field, uid) {
  try {
    const q = admin.firestore().collectionGroup(groupName).where(field, '==', uid);
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
  const doc = await admin.firestore().collection('users').doc(uid).get();
  const data = doc.exists ? (doc.data() || {}) : {};
  const key =
    data.idLower ||
    data.usernameLower ||
    (typeof data.id === 'string' ? data.id.toLowerCase() : undefined) ||
    (typeof displayName === 'string' ? displayName.toLowerCase() : undefined);
  if (key) {
    await admin.firestore().collection('usernames').doc(String(key)).delete().catch(() => {});
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
    const q = admin.firestore().collection('users').doc(uid).collection(s);
    const snap = await q.get();
    if (!snap.empty) {
      const writer = admin.firestore().bulkWriter();
      for (const d of snap.docs) writer.delete(d.ref);
      await writer.close();
    }
  }
  await admin.firestore().collection('users').doc(uid).delete().catch(() => {});
}

// 事前掃除（必要ならクライアントから呼ぶ）
exports.preDeleteCleanup = onCall(async (request) => {
  const { data, auth } = request;
  if (!auth || !auth.uid) throw new HttpsError('unauthenticated', 'Sign-in required');
  const caller = auth.uid;
  const uid = (data && data.uid) || caller;
  if (uid !== caller) throw new HttpsError('permission-denied', 'Cannot clean up other users');

  try {
    await _cleanupCrossUserLinks(uid);
    await _deleteAvatarFiles(uid);
    await _deleteUsernameMapping(uid, auth.token && auth.token.name);
    return { ok: true };
  } catch (e) {
    console.error('preDeleteCleanup failed:', uid, e);
    throw new HttpsError('internal', e.message || 'internal-error', { code: e.code, stack: e.stack });
  }
});

// Auth 削除後の最終掃除（v1 trigger, リージョン固定）
exports.onAuthUserDelete = functionsV1
  .region('asia-northeast1')
  .auth.user()
  .onDelete(async (user) => {
    const uid = user.uid;
    await _cleanupCrossUserLinks(uid);
    await _deleteAvatarFiles(uid);
    await _deleteUsernameMapping(uid, user.displayName || undefined);
    await _deleteUserTree(uid);
  });

// 代表的なサーバサイド削除（段階ログ付き）
exports.deleteAccountServerSide = onCall(async (request) => {
  const { auth } = request;
  if (!auth || !auth.uid) throw new HttpsError('unauthenticated', 'Sign-in required');
  const uid = auth.uid;

  // どこで落ちたかを特定するための段階ログ
  const step = (n, msg) => console.log(`[DEL ${uid}] #${n} ${msg}`);

  try {
    step(1, 'start');

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

    step(6, 'done');
    return { ok: true };
  } catch (e) {
    // ここに来ると iOS 側の FunctionsErrorDetailsKey に {where, message, code} が入る
    console.error(`[DEL ${uid}] FAILED`, e);
    if (e instanceof HttpsError) throw e;
    throw new HttpsError('internal', e.message || 'internal-error', { where: 'unknown', message: e.message, code: e.code, stack: e.stack });
  }
});
