#!/usr/bin/env node
/**
 * 半自動登録ツール: 募集ページのURLから careerListings ドキュメントを作る。
 *
 * 使い方（functions/ の firebase-admin を使用）:
 *   node scripts/add_career_listing.js <URL> --category shortTermIntern --source Wantedly \
 *        --company "株式会社〇〇" --deadline 2026-11-01 [--location 東京] [--pay "時給1,500円"] \
 *        [--schedule "..."] [--eligibility "..."] [--title "..."] [--desc "..."] [--days 60]
 *   -> まず下書きを表示するだけ（dry run）。内容を確認して --publish を付けると登録する。
 *
 * 認証: GOOGLE_APPLICATION_CREDENTIALS にサービスアカウントJSONを指定（プロジェクト forta-aogaku）。
 * 注意: 取得するのは公開メタ情報（og:title / og:description / og:image）のみ。本文の全文転載はしない。
 *       掲載元サイトの規約・転載可否を確認してから --publish すること。
 */
const path = require("path");
const CATEGORIES = ["longTermIntern", "shortTermIntern", "newGrad", "jobHunting",
                    "studyAbroad", "partTime", "recruitingEvent", "other"];

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const k = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) args[k] = true;
      else { args[k] = next; i++; }
    } else args._.push(a);
  }
  return args;
}

function meta(html, prop) {
  const re = new RegExp(`<meta[^>]+(?:property|name)=["']${prop}["'][^>]*>`, "i");
  const tag = (html.match(re) || [])[0];
  if (!tag) return null;
  const c = tag.match(/content=["']([^"']*)["']/i);
  return c ? decodeEntities(c[1]).trim() : null;
}

function decodeEntities(s) {
  return s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
          .replace(/&lt;/g, "<").replace(/&gt;/g, ">");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const url = args._[0];
  if (!url || !/^https:\/\//.test(url)) {
    console.error("https:// から始まる募集ページURLを指定してください"); process.exit(1);
  }
  const category = args.category || "other";
  if (!CATEGORIES.includes(category)) {
    console.error(`--category は次のいずれか: ${CATEGORIES.join(", ")}`); process.exit(1);
  }

  let html = "";
  try {
    const res = await fetch(url, { headers: { "User-Agent": "AogakuHackBot/1.0 (listing preview)" } });
    html = await res.text();
  } catch (e) {
    console.warn("ページ取得に失敗（手動入力で続行）:", e.message);
  }
  const ogTitle = meta(html, "og:title") || (html.match(/<title>([^<]*)<\/title>/i) || [])[1] || "";
  const ogDesc = meta(html, "og:description") || meta(html, "description") || "";
  const ogImage = meta(html, "og:image");
  const siteName = args.source || meta(html, "og:site_name") || new URL(url).hostname;

  const now = new Date();
  const days = Number(args.days || 60);
  const doc = {
    companyName: args.company || "",
    title: (args.title || ogTitle).trim(),
    description: (args.desc || ogDesc).slice(0, 200),
    eligibility: args.eligibility || "",
    location: args.location || "",
    compensation: args.pay || "",
    schedule: args.schedule || "",
    category,
    applicationUrl: url,
    sourceName: siteName,
    photoUrl: ogImage || null,
    applicationDeadline: args.deadline ? new Date(`${args.deadline}T23:59:00+09:00`) : null,
    publishedAt: now,
    expiresAt: args.deadline
      ? new Date(new Date(`${args.deadline}T23:59:00+09:00`).getTime() + 86400000)
      : new Date(now.getTime() + days * 86400000),
    isTrial: false,
    source: "manual",
  };

  console.log("---- 下書き ----");
  console.log(JSON.stringify(doc, null, 2));
  const missing = ["companyName", "title"].filter((k) => !doc[k]);
  if (missing.length) console.warn(`\n⚠ 未入力: ${missing.join(", ")}（--company / --title で指定）`);

  if (!args.publish) { console.log("\n(dry run) 登録するには --publish を付けて再実行"); return; }
  if (missing.length) process.exit(1);

  const admin = require(path.join(__dirname, "../functions/node_modules/firebase-admin"));
  admin.initializeApp({ projectId: "forta-aogaku" });
  const db = admin.firestore();
  // 同じURLの二重登録を防ぐ
  const dup = await db.collection("careerListings").where("applicationUrl", "==", url).limit(1).get();
  if (!dup.empty) { console.error(`既に登録済み: ${dup.docs[0].id}`); process.exit(1); }
  const ref = await db.collection("careerListings").add(doc);
  console.log(`✅ 登録しました: careerListings/${ref.id}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
