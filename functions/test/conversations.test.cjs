const test = require("node:test");
const assert = require("node:assert/strict");
const {CONVERSATION, validateMessages, validateDeleteIds, validateListCursor} = require("../lib/ai/conversations.js");
const NOW = Date.parse("2026-10-24T00:00:00Z");
const good = (over = {}) => ({id: "m1abcdef", role: "user", text: "こんにちは", createdAt: NOW - 1000, ...over});

test("文章の発言は、そのまま保存できる形になる", () => {
  const [row] = validateMessages({messages: [good()]}, NOW);
  assert.deepEqual(row, {id: "m1abcdef", role: "user", kind: "text", text: "こんにちは", imageCount: 0, createdAt: NOW - 1000});
});
test("画像の発言は、本文なしで、枚数だけを残す", () => {
  const [row] = validateMessages({messages: [good({kind: "image", text: "", imageCount: 3})]}, NOW);
  assert.equal(row.kind, "image"); assert.equal(row.text, ""); assert.equal(row.imageCount, 3);
  assert.equal(validateMessages({messages: [good({kind: "image", text: ""})]}, NOW)[0].imageCount, 1);
});
test("文章の発言が空、役割・種類が不正、長すぎる、重複は拒否する", () => {
  for (const bad of [good({text: "  "}), good({role: "system"}), good({kind: "video"}), good({text: "あ".repeat(CONVERSATION.maxText + 1)}), good({id: "a/b"}), good({createdAt: NOW + 10 * 86_400_000}), good({createdAt: 5}), good({imageCount: 99, kind: "image"})]) {
    assert.throws(() => validateMessages({messages: [bad]}, NOW));
  }
  assert.throws(() => validateMessages({messages: [good(), good()]}, NOW), /DUPLICATE/);
  assert.throws(() => validateMessages({messages: []}, NOW));
  assert.throws(() => validateMessages({messages: Array.from({length: CONVERSATION.maxBatch + 1}, (_, i) => good({id: "id" + i}))}, NOW));
  assert.throws(() => validateMessages({}, NOW));
});
test("削除するidと、続きを読む位置の検証", () => {
  assert.deepEqual(validateDeleteIds({ids: ["a1", "a1", "b2"]}), ["a1", "b2"]);
  assert.throws(() => validateDeleteIds({ids: []}));
  assert.throws(() => validateDeleteIds({ids: ["../x"]}));
  assert.equal(validateListCursor({}), undefined);
  assert.equal(validateListCursor({after: 1760000000000}), 1760000000000);
  assert.throws(() => validateListCursor({after: "x"}));
});
