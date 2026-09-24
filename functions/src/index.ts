import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";
import type { File } from "@google-cloud/storage";
admin.initializeApp();

const db = admin.firestore();
const region = "asia-northeast1";
const reactionPaperDailyLimit = 10;
const transcriptionMonthlyLimit = 10;
const transcriptionMaxDurationSeconds = 90 * 60;
const transcriptionMaxBytes = 100 * 1024 * 1024;
const transcriptionMaxChunkCount = 8;
// Groq allows up to 224 prompt tokens. Keep a conservative character cap because
// Japanese tokenization varies, and the client intentionally sends a compact glossary.
const transcriptionContextMaxLength = 240;
const groqTurboModel = "whisper-large-v3-turbo";
const groqAccurateModel = "whisper-large-v3";
// 授業AIチャット: 直近何件を生ログのままLLMへ渡すか、何件溜まったら要約に畳み込むか
const chatHistoryWindow = 10;
const chatSummarizeThreshold = 20;

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

// 文字数を上限内に丸め、想定外の長さの入力によるコスト増を防ぐ
function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  return text.slice(0, maxLength) + "\n…(以下省略)";
}

function tokyoDateKey(date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

function tokyoMonthKey(date = new Date()): string {
  const [year, month] = tokyoDateKey(date).split("-");
  return `${year}-${month}`;
}

function quotaCounterRef(uid: string, counterId: string) {
  // Keep billing limits outside the user-owned subtree so clients cannot reset them.
  return db
    .collection("privateUsage")
    .doc(uid)
    .collection("counters")
    .doc(counterId);
}

async function consumeTranscriptionQuota(uid: string): Promise<{ monthKey: string; remaining: number }> {
  const monthKey = tokyoMonthKey();
  const ref = quotaCounterRef(uid, `transcription_${monthKey}`);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const currentCount = Number(snap.get("count") ?? 0);
    if (currentCount >= transcriptionMonthlyLimit) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        `今月のAI文字起こしは上限(${transcriptionMonthlyLimit}回)に達しました。`
      );
    }

    const nextCount = currentCount + 1;
    tx.set(
      ref,
      {
        kind: "transcription",
        monthKey,
        count: nextCount,
        limit: transcriptionMonthlyLimit,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: snap.exists
          ? (snap.get("createdAt") ?? admin.firestore.FieldValue.serverTimestamp())
          : admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    return { monthKey, remaining: transcriptionMonthlyLimit - nextCount };
  });
}

async function refundTranscriptionQuota(uid: string, monthKey: string): Promise<void> {
  const ref = quotaCounterRef(uid, `transcription_${monthKey}`);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const currentCount = Number(snap.get("count") ?? 0);
    tx.set(
      ref,
      {
        count: Math.max(0, currentCount - 1),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  });
}

async function consumeReactionPaperQuota(uid: string): Promise<{ dateKey: string; remaining: number }> {
  const dateKey = tokyoDateKey();
  const ref = quotaCounterRef(uid, `reactionPaper_${dateKey}`);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const currentCount = Number(snap.get("count") ?? 0);
    if (currentCount >= reactionPaperDailyLimit) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        `本日の生成回数が上限(${reactionPaperDailyLimit}回)に達しました。明日またお試しください。`
      );
    }

    const nextCount = currentCount + 1;
    tx.set(
      ref,
      {
        kind: "reactionPaper",
        dateKey,
        count: nextCount,
        limit: reactionPaperDailyLimit,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: snap.exists
          ? (snap.get("createdAt") ?? admin.firestore.FieldValue.serverTimestamp())
          : admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    return { dateKey, remaining: reactionPaperDailyLimit - nextCount };
  });
}

async function refundReactionPaperQuota(uid: string, dateKey: string): Promise<void> {
  const ref = quotaCounterRef(uid, `reactionPaper_${dateKey}`);

  await ref.set(
    {
      count: admin.firestore.FieldValue.increment(-1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

type GroqSegment = {
  text?: string;
  start?: number;
  end?: number;
  avg_logprob?: number;
  compression_ratio?: number;
  no_speech_prob?: number;
};

type GroqTranscription = {
  text?: string;
  segments?: GroqSegment[];
};

type TranscriptionQualitySummary = {
  segmentCount: number;
  suspiciousSegmentCount: number;
  averageLogProbability: number | null;
  highNoSpeechSegmentCount: number;
  highCompressionSegmentCount: number;
};

class GroqUnavailableError extends Error {
  constructor(readonly status?: number) {
    super("Groq is temporarily unavailable");
  }
}

function hasSuspiciousRepetition(text: string): boolean {
  const normalized = text.replace(/\s+/g, " ").trim();
  if (normalized.length < 40) return false;

  const samples = new Map<string, number>();
  const sampleLength = 24;
  const step = 12;
  for (let index = 0; index + sampleLength <= normalized.length; index += step) {
    const sample = normalized.slice(index, index + sampleLength);
    const count = (samples.get(sample) ?? 0) + 1;
    if (count >= 3) return true;
    samples.set(sample, count);
  }
  return false;
}

function shouldRetryWithAccurateModel(result: GroqTranscription): boolean {
  const text = result.text?.trim() ?? "";
  if (!text || hasSuspiciousRepetition(text)) return true;

  const speechSegments = (result.segments ?? []).filter((segment) =>
    (segment.text?.trim().length ?? 0) > 0 && (segment.no_speech_prob ?? 0) < 0.8
  );
  if (speechSegments.length === 0) return false;

  const lowConfidenceCount = speechSegments.filter(
    (segment) => Number.isFinite(segment.avg_logprob) && (segment.avg_logprob as number) < -1.15
  ).length;
  const compressedCount = speechSegments.filter(
    (segment) => Number.isFinite(segment.compression_ratio) &&
      (segment.compression_ratio as number) > 2.4
  ).length;

  return lowConfidenceCount / speechSegments.length >= 0.5 || compressedCount > 0;
}

function summarizeTranscriptionQuality(result: GroqTranscription): TranscriptionQualitySummary {
  const segments = result.segments ?? [];
  const speechSegments = segments.filter((segment) =>
    (segment.text?.trim().length ?? 0) > 0 && (segment.no_speech_prob ?? 0) < 0.8
  );
  const logProbabilities = speechSegments
    .map((segment) => segment.avg_logprob)
    .filter((value): value is number => Number.isFinite(value));
  const lowConfidenceCount = speechSegments.filter(
    (segment) => Number.isFinite(segment.avg_logprob) && (segment.avg_logprob as number) < -1.15
  ).length;
  const highCompressionSegmentCount = speechSegments.filter(
    (segment) => Number.isFinite(segment.compression_ratio) &&
      (segment.compression_ratio as number) > 2.4
  ).length;
  const highNoSpeechSegmentCount = segments.filter(
    (segment) => (segment.text?.trim().length ?? 0) > 0 && (segment.no_speech_prob ?? 0) >= 0.8
  ).length;

  return {
    segmentCount: segments.length,
    suspiciousSegmentCount: lowConfidenceCount + highCompressionSegmentCount +
      highNoSpeechSegmentCount + (hasSuspiciousRepetition(result.text ?? "") ? 1 : 0),
    averageLogProbability: logProbabilities.length > 0
      ? logProbabilities.reduce((sum, value) => sum + value, 0) / logProbabilities.length
      : null,
    highNoSpeechSegmentCount,
    highCompressionSegmentCount,
  };
}

function aggregateQuality(
  summaries: TranscriptionQualitySummary[]
): TranscriptionQualitySummary {
  const weightedLogProbability = summaries.reduce(
    (acc, summary) => {
      if (summary.averageLogProbability === null) return acc;
      return {
        sum: acc.sum + summary.averageLogProbability * summary.segmentCount,
        count: acc.count + summary.segmentCount,
      };
    },
    { sum: 0, count: 0 }
  );
  return {
    segmentCount: summaries.reduce((sum, summary) => sum + summary.segmentCount, 0),
    suspiciousSegmentCount: summaries.reduce(
      (sum, summary) => sum + summary.suspiciousSegmentCount, 0
    ),
    averageLogProbability: weightedLogProbability.count > 0
      ? weightedLogProbability.sum / weightedLogProbability.count
      : null,
    highNoSpeechSegmentCount: summaries.reduce(
      (sum, summary) => sum + summary.highNoSpeechSegmentCount, 0
    ),
    highCompressionSegmentCount: summaries.reduce(
      (sum, summary) => sum + summary.highCompressionSegmentCount, 0
    ),
  };
}

function textAfterOverlap(result: GroqTranscription, overlapSeconds: number): string {
  const segments = result.segments ?? [];
  if (overlapSeconds > 0 && segments.length > 0) {
    const kept = segments
      .filter((segment) => (segment.end ?? 0) > overlapSeconds)
      .map((segment) => segment.text?.trim() ?? "")
      .filter(Boolean);
    if (kept.length > 0) return kept.join(" ");
  }
  return result.text?.trim() ?? "";
}

function mergeTranscript(existing: string, next: string): string {
  if (!existing) return next;
  if (!next) return existing;

  const maxOverlap = Math.min(160, existing.length, next.length);
  for (let length = maxOverlap; length >= 12; length -= 1) {
    if (existing.slice(-length) === next.slice(0, length)) {
      return `${existing}${next.slice(length)}`;
    }
  }
  return `${existing}\n${next}`;
}

async function transcribeWithGroq(
  signedUrl: string,
  model: string,
  contextPrompt: string,
  apiKey: string
): Promise<GroqTranscription> {
  const form = new FormData();
  form.append("url", signedUrl);
  form.append("model", model);
  form.append("language", "ja");
  form.append("response_format", "verbose_json");
  form.append("timestamp_granularities[]", "segment");
  form.append("temperature", "0");
  if (contextPrompt) form.append("prompt", contextPrompt);

  let response: Response;
  try {
    response = await fetch("https://api.groq.com/openai/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
    });
  } catch (error) {
    console.error("Groq transcription network error", model, error);
    throw new GroqUnavailableError();
  }

  if (!response.ok) {
    const responseText = await response.text();
    console.error("Groq transcription error", model, response.status, responseText.slice(0, 1000));
    if (response.status === 429 || response.status >= 500) {
      throw new GroqUnavailableError(response.status);
    }
    throw new functions.https.HttpsError("internal", "AI文字起こしに失敗しました");
  }

  return (await response.json()) as GroqTranscription;
}

async function transcribeWithOpenAI(
  signedUrl: string,
  contextPrompt: string,
  apiKey: string
): Promise<GroqTranscription> {
  const audioResponse = await fetch(signedUrl);
  if (!audioResponse.ok) {
    throw new functions.https.HttpsError("internal", "一時音声の読み込みに失敗しました");
  }

  const form = new FormData();
  form.append("file", await audioResponse.blob(), "lecture.m4a");
  form.append("model", "gpt-transcribe");
  form.append("language", "ja");
  form.append("response_format", "json");
  if (contextPrompt) form.append("prompt", contextPrompt);

  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });
  if (!response.ok) {
    const responseText = await response.text();
    console.error("OpenAI transcription fallback error", response.status, responseText.slice(0, 1000));
    throw new functions.https.HttpsError("internal", "AI文字起こしに失敗しました");
  }
  return (await response.json()) as GroqTranscription;
}

async function cleanTranscriptSpelling(
  rawTranscript: string,
  contextPrompt: string,
  apiKey: string
): Promise<string> {
  if (!rawTranscript.trim()) return "";
  const prompt = `次の大学講義の音声認識結果を校正してください。

厳守事項:
- 誤字、句読点、明らかな固有名詞・専門用語の表記だけを修正する
- 内容の追加、削除、要約、並べ替え、言い換えをしない
- 聞き取れない箇所を推測で補わない
- 判断できない表現は原文のまま残す
- 修正後の本文だけを出力する

参考用語:
${contextPrompt || "(なし)"}

原文:
${rawTranscript}`;

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: prompt }],
      temperature: 0,
    }),
  });
  if (!response.ok) {
    const responseText = await response.text();
    console.error("Transcript cleanup error", response.status, responseText.slice(0, 1000));
    return rawTranscript;
  }

  const json = (await response.json()) as {
    choices?: { message?: { content?: string } }[];
  };
  const cleaned = json.choices?.[0]?.message?.content?.trim() ?? "";
  // A large length change indicates that the model edited content rather than spelling.
  const lengthRatio = cleaned.length / Math.max(rawTranscript.length, 1);
  if (!cleaned || lengthRatio < 0.8 || lengthRatio > 1.25) {
    console.warn("Transcript cleanup discarded", { rawLength: rawTranscript.length, cleanedLength: cleaned.length });
    return rawTranscript;
  }
  return cleaned;
}

/**
 * 授業AI: Firebase Storageに一時アップロードされた授業音声を
 * Groq Whisper Large V3 Turboで文字起こしし、品質が低い区間だけLarge V3で再処理する。
 * 音声は処理後に必ず削除する。
 */
export const transcribeLectureAudio = functions
  .region(region)
  .runWith({ secrets: ["GROQ_API_KEY", "OPENAI_API_KEY"], timeoutSeconds: 540, memory: "512MB" })
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "サインインが必要です");
    }

    const uid = context.auth.uid;
    const requestedPaths = Array.isArray(data.storagePaths)
      ? data.storagePaths.map((value: unknown) => String(value))
      : [String(data.storagePath ?? "")];
    const storagePaths = requestedPaths.filter(Boolean);
    const durationSeconds = Math.ceil(Number(data.durationSeconds) || 0);
    const chunkOverlapSeconds = Math.min(Math.max(Number(data.chunkOverlapSeconds) || 0, 0), 10);
    const contextPrompt = truncate(String(data.contextPrompt ?? ""), transcriptionContextMaxLength)
      .replace(/\s+/g, " ")
      .trim();
    const allowedPath = new RegExp(
      `^users/${uid.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/transcriptionUploads/[A-Za-z0-9-]+\\.m4a$`
    );

    if (
      storagePaths.length === 0 ||
      storagePaths.length > transcriptionMaxChunkCount ||
      storagePaths.some((storagePath: string) => !allowedPath.test(storagePath))
    ) {
      throw new functions.https.HttpsError("invalid-argument", "音声ファイルの指定が不正です");
    }
    if (durationSeconds <= 0 || durationSeconds > transcriptionMaxDurationSeconds) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "録音は1回90分以内にしてください"
      );
    }

    const files: File[] = storagePaths.map(
      (storagePath: string) => admin.storage().bucket().file(storagePath)
    );
    const existence = await Promise.all(files.map((file) => file.exists()));
    if (existence.some(([exists]) => !exists)) {
      await Promise.all(files.map((file) => file.delete({ ignoreNotFound: true })));
      throw new functions.https.HttpsError("not-found", "音声ファイルが見つかりません");
    }

    const metadataResults = await Promise.all(files.map((file) => file.getMetadata()));
    const fileSizes = metadataResults.map(([metadata]) => Number(metadata.size ?? 0));
    const totalFileSize = fileSizes.reduce((sum, size) => sum + size, 0);
    if (fileSizes.some((size) => size <= 0) || totalFileSize > transcriptionMaxBytes) {
      await Promise.all(files.map((file) => file.delete({ ignoreNotFound: true })));
      throw new functions.https.HttpsError("invalid-argument", "音声ファイルのサイズが上限を超えています");
    }

    const quota = await consumeTranscriptionQuota(uid);
    let succeeded = false;

    try {
      const apiKey = process.env.GROQ_API_KEY;
      if (!apiKey) {
        throw new functions.https.HttpsError("failed-precondition", "Groq APIキーが設定されていません");
      }

      let rawTranscript = "";
      let cleanedTranscript = "";
      let accurateChunkCount = 0;
      let openAIFallbackChunkCount = 0;
      let retryImprovedChunkCount = 0;
      const turboQualitySummaries: TranscriptionQualitySummary[] = [];
      const finalQualitySummaries: TranscriptionQualitySummary[] = [];

      for (let index = 0; index < files.length; index += 1) {
        const [signedUrl] = await files[index].getSignedUrl({
          action: "read",
          expires: Date.now() + 15 * 60 * 1000,
        });
        let result: GroqTranscription;
        try {
          result = await transcribeWithGroq(signedUrl, groqTurboModel, contextPrompt, apiKey);
          const turboQuality = summarizeTranscriptionQuality(result);
          turboQualitySummaries.push(turboQuality);
          if (shouldRetryWithAccurateModel(result)) {
            result = await transcribeWithGroq(signedUrl, groqAccurateModel, contextPrompt, apiKey);
            accurateChunkCount += 1;
            const accurateQuality = summarizeTranscriptionQuality(result);
            if (
              accurateQuality.suspiciousSegmentCount < turboQuality.suspiciousSegmentCount ||
              (
                accurateQuality.averageLogProbability !== null &&
                turboQuality.averageLogProbability !== null &&
                accurateQuality.averageLogProbability > turboQuality.averageLogProbability
              )
            ) {
              retryImprovedChunkCount += 1;
            }
          }
        } catch (error) {
          if (!(error instanceof GroqUnavailableError)) throw error;
          const openAIApiKey = process.env.OPENAI_API_KEY;
          if (!openAIApiKey) {
            throw new functions.https.HttpsError(
              "resource-exhausted",
              "AI文字起こしが混み合っています。しばらくしてからもう一度お試しください"
            );
          }
          result = await transcribeWithOpenAI(signedUrl, contextPrompt, openAIApiKey);
          openAIFallbackChunkCount += 1;
        }

        finalQualitySummaries.push(summarizeTranscriptionQuality(result));

        const chunkText = textAfterOverlap(result, index === 0 ? 0 : chunkOverlapSeconds);
        rawTranscript = mergeTranscript(rawTranscript, chunkText);
        const openAIApiKey = process.env.OPENAI_API_KEY;
        const cleanedChunk = openAIApiKey
          ? await cleanTranscriptSpelling(chunkText, contextPrompt, openAIApiKey)
          : chunkText;
        cleanedTranscript = mergeTranscript(cleanedTranscript, cleanedChunk);
      }

      rawTranscript = rawTranscript.trim();
      cleanedTranscript = cleanedTranscript.trim() || rawTranscript;
      if (!rawTranscript) {
        throw new functions.https.HttpsError("internal", "文字起こし結果が空でした");
      }

      const turboQuality = aggregateQuality(turboQualitySummaries);
      const finalQuality = aggregateQuality(finalQualitySummaries);
      const model = [
        groqTurboModel,
        accurateChunkCount > 0 ? groqAccurateModel : "",
        openAIFallbackChunkCount > 0 ? "gpt-transcribe" : "",
      ].filter(Boolean).join("+");

      console.info("Lecture transcription completed", {
        durationSeconds,
        chunkCount: files.length,
        accurateChunkCount,
        openAIFallbackChunkCount,
        retryImprovedChunkCount,
        transcriptLength: rawTranscript.length,
        turboQuality,
        finalQuality,
      });
      succeeded = true;
      return {
        text: cleanedTranscript,
        rawTranscript,
        cleanedTranscript,
        model,
        chunkCount: files.length,
        accurateChunkCount,
        openAIFallbackChunkCount,
        retryImprovedChunkCount,
        turboQuality,
        finalQuality,
        remainingTranscriptionsThisMonth: quota.remaining,
      };
    } catch (error) {
      if (error instanceof functions.https.HttpsError) throw error;
      console.error("transcribeLectureAudio failed", error);
      throw new functions.https.HttpsError("internal", "AI文字起こしに失敗しました");
    } finally {
      await Promise.all(files.map((file, index) =>
        file.delete({ ignoreNotFound: true }).catch((error: unknown) => {
          console.error("Temporary audio deletion failed", storagePaths[index], error);
        })
      ));
      if (!succeeded) {
        await refundTranscriptionQuota(uid, quota.monthKey).catch((error) => {
          console.error("Transcription quota refund failed", uid, error);
        });
      }
    }
  });

/**
 * 授業ノート(AI)機能: 録音の文字起こし・撮影したテキスト・シラバス概要をもとに、
 * 指定文字数のテキストを生成する。OpenAI APIキーはシークレット(OPENAI_API_KEY)で管理する。
 */
export const generateReactionPaper = functions
  .region(region)
  .runWith({ secrets: ["OPENAI_API_KEY"], timeoutSeconds: 120, memory: "256MB" })
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "サインインが必要です");
    }

    const transcript = truncate(String(data.transcript ?? ""), 50000);
    const photoText = truncate(String(data.photoText ?? ""), 16000);
    const syllabusOverview = truncate(String(data.syllabusOverview ?? ""), 4000);
    const assignmentInstructions = truncate(String(data.assignmentInstructions ?? ""), 1000);
    const personalNotes = truncate(String(data.personalNotes ?? ""), 2000);
    const targetLength = Math.min(Math.max(Math.round(Number(data.targetLength) || 400), 100), 2000);

    if (!transcript && !photoText) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "文字起こしまたは撮影内容が必要です"
      );
    }

    const uid = context.auth.uid;
    const quota = await consumeReactionPaperQuota(uid);

    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      await refundReactionPaperQuota(uid, quota.dateKey);
      throw new functions.https.HttpsError("failed-precondition", "APIキーが設定されていません");
    }

    const prompt = `あなたは大学の授業内容を深く理解し、自然で説得力のあるリアクションペーパーを書く支援者です。

これから、授業の録音文字起こし、シラバス、配布プリント、板書メモ、課題指示などの情報を渡します。それらをもとに、以下の条件でリアクションペーパーを作成してください。

# 目的
単なる授業内容の要約ではなく、授業の核心を正確に押さえたうえで、自分なりの問題意識・気づき・疑問・具体例を含む、評価されやすいリアクションペーパーにしてください。

# 書き方の条件
- 授業内容を正確に理解していることが伝わるようにする
- 重要概念やキーワードを自然に使う
- 「面白かった」「勉強になった」だけで終わらせない
- 授業内容と自分の考えを結びつける
- 具体例、現代社会との接点、自分の経験、別の授業との関連などを入れる
- 最後に今後考えたい問いや、授業を通じて残った疑問を入れる
- 大学生らしい自然な文体にする
- 不自然にAIっぽい表現、過度に立派すぎる表現、抽象的すぎる一般論は避ける
- 教員に媚びるような表現は避ける
- 断定しすぎず、考察の余地を残す
- 授業で話されていない内容や資料にない内容を、憶測で書き加えない。情報が不足している場合は「この点は授業情報からは確認できない」と書く

# 構成
1. 授業で扱われた中心テーマを簡潔に示す
2. 特に印象に残った論点・概念を説明する
3. それについて自分がどう考えたかを書く
4. 授業内容を具体例や現代的な問題と結びつける
5. 最後に、残った疑問や今後考えたい問いで締める

# 出力条件
- です・ます調で書く
- 日本語でちょうど${targetLength}字程度にする
- 要約3割、考察7割くらいの比率を意識する

それでは、以下の授業情報をもとにリアクションペーパーを作成してください。

【課題指示】
${assignmentInstructions || "(なし)"}

【シラバス】
${syllabusOverview || "(なし)"}

【授業録音・文字起こし】
${transcript || "(なし)"}

【配布資料・板書メモ】
${photoText || "(なし)"}

【自分の感想・入れたい視点】
${personalNotes || "(特になし。自然に書いてよい)"}`;

    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        messages: [{ role: "user", content: prompt }],
        temperature: 0.5,
      }),
    });

    if (!res.ok) {
      const errText = await res.text();
      console.error("OpenAI API error", res.status, errText);
      await refundReactionPaperQuota(uid, quota.dateKey);
      throw new functions.https.HttpsError("internal", "生成に失敗しました");
    }

    const json = (await res.json()) as {
      choices?: { message?: { content?: string } }[];
    };
    const text = json.choices?.[0]?.message?.content?.trim() ?? "";
    if (!text) {
      await refundReactionPaperQuota(uid, quota.dateKey);
      throw new functions.https.HttpsError("internal", "生成結果が空でした");
    }

    return { text, remainingGenerationsToday: quota.remaining };
  });

type CourseChatRole = "user" | "assistant";
type CourseChatMessage = { role: CourseChatRole; content: string };

function courseChatDocRef(uid: string, courseKey: string) {
  return db.collection("users").doc(uid).collection("courseChats").doc(courseKey);
}

function courseChatMessagesRef(uid: string, courseKey: string) {
  return courseChatDocRef(uid, courseKey).collection("messages");
}

/** ローリング要約と、直近 chatHistoryWindow 件の生ログを取得する */
async function fetchCourseChatContext(
  uid: string,
  courseKey: string
): Promise<{ summary: string; summarizedMessageCount: number; recentMessages: CourseChatMessage[] }> {
  const chatDoc = await courseChatDocRef(uid, courseKey).get();
  const summary = String(chatDoc.get("summary") ?? "");
  const summarizedMessageCount = Number(chatDoc.get("summarizedMessageCount") ?? 0);

  const snap = await courseChatMessagesRef(uid, courseKey)
    .orderBy("createdAt", "desc")
    .limit(chatHistoryWindow)
    .get();
  const recentMessages = snap.docs
    .map((d) => ({ role: d.get("role") as CourseChatRole, content: String(d.get("content") ?? "") }))
    .reverse();

  return { summary, summarizedMessageCount, recentMessages };
}

/** 新しいユーザー発話とAI応答を会話ログに追記する */
async function persistCourseChatTurn(
  uid: string,
  courseKey: string,
  userPrompt: string,
  answer: string
): Promise<void> {
  const messagesRef = courseChatMessagesRef(uid, courseKey);
  const batch = db.batch();
  batch.set(messagesRef.doc(), {
    role: "user",
    content: userPrompt,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  batch.set(messagesRef.doc(), {
    role: "assistant",
    content: answer,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  batch.set(
    courseChatDocRef(uid, courseKey),
    { updatedAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true }
  );
  await batch.commit();
}

/**
 * 会話が chatSummarizeThreshold 件以上溜まっていたら、直近 chatHistoryWindow 件を除く
 * 未要約分をローリング要約へ畳み込む。失敗しても回答自体は返せるよう呼び出し側で握りつぶす。
 */
async function maybeSummarizeCourseChat(
  uid: string,
  courseKey: string,
  apiKey: string,
  previousSummary: string,
  previousSummarizedCount: number
): Promise<void> {
  const snap = await courseChatMessagesRef(uid, courseKey).orderBy("createdAt", "asc").get();
  const total = snap.size;
  if (total - previousSummarizedCount < chatSummarizeThreshold) return;

  const foldCount = total - chatHistoryWindow;
  if (foldCount <= previousSummarizedCount) return;

  const toFold = snap.docs.slice(previousSummarizedCount, foldCount);
  const logText = toFold
    .map((d) => `${d.get("role") === "user" ? "学生" : "AI"}: ${String(d.get("content") ?? "")}`)
    .join("\n");

  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${apiKey}` },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [
        {
          role: "system",
          content:
            "あなたは授業AIの会話ログを圧縮する要約者です。事実関係を変えず、話されていない内容を補わず、" +
            "後で参照できるよう日本語300字程度に圧縮してください。既存の要約があれば、新しいログの内容で更新・統合してください。",
        },
        {
          role: "user",
          content: `【これまでの要約】\n${previousSummary || "(なし)"}\n\n【新しく畳み込む会話ログ】\n${logText}`,
        },
      ],
      temperature: 0.2,
      max_tokens: 500,
    }),
  });
  if (!res.ok) {
    console.error("courseChat summarize failed", res.status, await res.text());
    return;
  }
  const json = (await res.json()) as { choices?: { message?: { content?: string } }[] };
  const newSummary = json.choices?.[0]?.message?.content?.trim();
  if (!newSummary) return;

  await courseChatDocRef(uid, courseKey).set(
    {
      summary: newSummary,
      summarizedMessageCount: foldCount,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

/**
 * 授業AI: 自由入力を短いタスクとして受け取り、授業記録だけを根拠に回答する。
 * 入出力と日次回数を制限し、チャットUIでも生成コストが膨らまないようにする。
 * courseKeyが渡された場合、直近の会話は生ログ、それより古い分はローリング要約として
 * Firestore(users/{uid}/courseChats/{courseKey})に永続化し、次回以降のリクエストに使う。
 */
export const askCourseAI = functions
  .region(region)
  .runWith({ secrets: ["OPENAI_API_KEY"], timeoutSeconds: 120, memory: "256MB" })
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError("unauthenticated", "サインインが必要です");
    }

    const userPrompt = truncate(String(data.prompt ?? "").trim(), 200);
    const transcript = truncate(String(data.transcript ?? ""), 32000);
    const photoText = truncate(String(data.photoText ?? ""), 12000);
    const syllabusOverview = truncate(String(data.syllabusOverview ?? ""), 4000);
    const courseKey = String(data.courseKey ?? "").trim();
    if (!userPrompt) {
      throw new functions.https.HttpsError("invalid-argument", "質問を入力してください");
    }
    if (!transcript && !photoText && !syllabusOverview) {
      throw new functions.https.HttpsError("invalid-argument", "使える授業内容がありません");
    }

    const lengthMatch = userPrompt.match(/(\d{2,4})\s*字/);
    const requestedLength = lengthMatch
      ? Math.min(Math.max(Number(lengthMatch[1]), 100), 2000)
      : null;
    const uid = context.auth.uid;
    const quota = await consumeReactionPaperQuota(uid);
    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      await refundReactionPaperQuota(uid, quota.dateKey);
      throw new functions.https.HttpsError("failed-precondition", "APIキーが設定されていません");
    }

    const chatContext = courseKey
      ? await fetchCourseChatContext(uid, courseKey)
      : { summary: "", summarizedMessageCount: 0, recentMessages: [] as CourseChatMessage[] };

    const systemPrompt = `あなたは、特定の大学授業だけを継続して覚えている「授業AI」です。
ユーザーの依頼を、リアクションペーパー、要約、小テスト、授業内容への質問のいずれかとして扱ってください。

必須ルール:
- 回答の根拠は、下に渡すシラバス・文字起こし・資料だけに限定する
- 記録にない事実を補わない。不明な場合は、授業記録からは確認できないと明示する
- リアクションペーパーは大学生らしい自然なです・ます調で、要約だけでなく考察を中心にする
- 小テストは問題を先にまとめ、その後に「解答と解説」を分けて載せる
- 質問には結論から簡潔に答え、必要なら授業回を示す
- ユーザーが指定した形式と文字数を優先する
- 最大2000字以内で回答する${requestedLength ? `\n- 今回は${requestedLength}字程度にする` : ""}`;

    const requestPrompt = `【ユーザーの依頼】
${userPrompt}

【シラバス】
${syllabusOverview || "(なし)"}

【授業の文字起こし】
${transcript || "(なし)"}

【配布資料・撮影内容】
${photoText || "(なし)"}`;

    try {
      const messages: { role: string; content: string }[] = [{ role: "system", content: systemPrompt }];
      if (chatContext.summary) {
        messages.push({ role: "system", content: `これまでの会話の要約:\n${chatContext.summary}` });
      }
      for (const m of chatContext.recentMessages) {
        messages.push({ role: m.role, content: m.content });
      }
      messages.push({ role: "user", content: requestPrompt });

      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${apiKey}`,
        },
        body: JSON.stringify({
          model: "gpt-4o-mini",
          messages,
          temperature: 0.4,
          max_tokens: 2400,
        }),
      });

      if (!response.ok) {
        const responseText = await response.text();
        console.error("Course AI error", response.status, responseText.slice(0, 1000));
        throw new Error("Course AI request failed");
      }

      const json = (await response.json()) as {
        choices?: { message?: { content?: string } }[];
      };
      const text = json.choices?.[0]?.message?.content?.trim() ?? "";
      if (!text) throw new Error("Course AI returned an empty response");

      if (courseKey) {
        try {
          await persistCourseChatTurn(uid, courseKey, userPrompt, text);
          await maybeSummarizeCourseChat(
            uid,
            courseKey,
            apiKey,
            chatContext.summary,
            chatContext.summarizedMessageCount
          );
        } catch (persistError) {
          console.error("courseChat persist/summarize failed", persistError);
        }
      }

      return { text, remainingGenerationsToday: quota.remaining };
    } catch (error) {
      await refundReactionPaperQuota(uid, quota.dateKey);
      console.error("askCourseAI failed", error);
      throw new functions.https.HttpsError("internal", "回答の生成に失敗しました");
    }
  });
