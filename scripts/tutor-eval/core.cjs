'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {cases: legacy, norm: legacyNorm} = require('./legacy.cjs');
const GATES = ['grounding', 'correctness', 'task_completion', 'uncertainty'];
const VERSION = 'tutor-rubric-v1';
const scoringHash = () => hash(Buffer.concat([fs.readFileSync(__filename),fs.readFileSync(path.join(__dirname,'legacy.cjs'))]));
const sameVisible = (a,b) => a.trim().replace(/\n{3,}/g,'\n\n') === b.trim().replace(/\n{3,}/g,'\n\n');
const hash = x => crypto.createHash('sha256').update(x).digest('hex');
const canonical = x => JSON.stringify(x);
// Remove LaTeX formatting BEFORE deleting backslashes; keep mathematical content.
function norm(s) { return s.replace(/²/g, '^2').normalize('NFKC').replace(/\\(?:text|mathrm|mathbf|mathit|operatorname)(?=\{)/g, '').replace(/\\(?:left|right|,|!|;|quad|qquad)/g, '').replace(/\\(?:leq?|leqslant)/g, '<=').replace(/\\(?:geq?|geqslant)/g, '>=').replace(/[≤]/g, '<=').replace(/[≥]/g, '>=').replace(/[−–]/g, '-').replace(/²/g, '^2').replace(/[\s*$\\{}]/g, ''); }
function validateCase(c) {
  if (!c || !/^[a-z][a-z0-9-]+$/.test(c.id) || !Number.isSafeInteger(c.version) || c.version < 1 || !['dev','holdout'].includes(c.split) || typeof c.familyId !== 'string' || !c.familyId) throw Error('INVALID_CASE_IDENTITY');
  if (!Array.isArray(c.tags) || !c.tags.length || c.tags.some(t => typeof t !== 'string') || !Array.isArray(c.images) || c.images.some(f => typeof f !== 'string' || path.basename(f) !== f) || !Array.isArray(c.context) || c.context.some(x => !x || typeof x.title !== 'string' || typeof x.text !== 'string')) throw Error('INVALID_CASE_SOURCE');
  if (!c.images.length && !c.context.length) throw Error('EMPTY_CASE_SOURCE');
  if (!Array.isArray(c.questions) || !c.questions.length || c.questions.length > 6 || c.questions.some(q => typeof q !== 'string' || !q.trim())) throw Error('INVALID_SCENARIO');
  if (!c.rubric || GATES.some(g => typeof c.rubric[g] !== 'string' || !c.rubric[g])) throw Error('MISSING_RUBRIC');
  if (!Array.isArray(c.suggestionAnchors) || c.suggestionAnchors.some(a => typeof a !== 'string' || !a)) throw Error('INVALID_ANCHORS');
  if (c.legacyCase !== undefined && (!Number.isInteger(c.legacyCase) || c.legacyCase < 1 || c.legacyCase > legacy.length)) throw Error('INVALID_LEGACY_CASE');
  if (c.checks !== undefined && (!Array.isArray(c.checks) || c.checks.some(x => !x || !GATES.includes(x.gate) || !['includes','excludes','any'].includes(x.kind) || (x.kind === 'any' ? !Array.isArray(x.values) || !x.values.length || x.values.some(v => typeof v !== 'string' || !v) : typeof x.value !== 'string' || !x.value)))) throw Error('INVALID_CHECK');
  return c;
}
function loadCases(root, split, only) {
  const all = [];
  for (const s of ['dev','holdout']) {
    for (const f of fs.readdirSync(path.join(root,s)).filter(f => f.endsWith('.json')).sort()) {
      const c = validateCase(JSON.parse(fs.readFileSync(path.join(root,s,f),'utf8')));
      if (c.split !== s || all.some(a => a.id === c.id)) throw Error('CASE_SPLIT_OR_DUPLICATE');
      all.push(c);
    }
  }
  const families = new Map();
  for (const c of all) { if (families.has(c.familyId) && families.get(c.familyId) !== c.split) throw Error('SPLIT_FAMILY_LEAKAGE'); families.set(c.familyId,c.split); }
  if (only && only.some(id => !all.some(c => c.split === split && c.id === id))) throw Error('UNKNOWN_CASE_SELECTION');
  const selected = all.filter(c => c.split === split && (!only || only.includes(c.id)));
  if (!selected.length) throw Error('EMPTY_SELECTION');
  return selected;
}
function score(c, reply) {
  const text = reply.text, n = norm(text), failures = [];
  const finishes=reply.provider?.finishReasons;
  const completion=Array.isArray(finishes)&&finishes.length ? (finishes.every(f=>f==='STOP')?'confirmed':'incomplete') : 'unobserved';
  if(completion==='incomplete')failures.push({gate:'task_completion',category:'provider_output',reason:'providerが正常完了を確認していない',finishReasons:finishes});
  if (text.includes('[[')) failures.push({gate:'grounding', category:'format', reason:'内部マーカーが本文に残る'});
  for (const check of c.checks || []) {
    const ok = check.kind === 'any' ? check.values.some(v => n.includes(norm(v))) : check.kind === 'includes' ? n.includes(norm(check.value)) : !n.includes(norm(check.value));
    if (!ok) failures.push({gate:check.gate, category:check.gate, reason:'必須内容または禁止内容の機械チェック失敗', check});
  }
  const legacyFailures = c.legacyCase ? legacy[c.legacyCase - 1][3](text, legacyNorm(text)).filter(x => typeof x === 'string') : null;
  const suggestions = reply.suggestions || [];
  const noteAt=text.indexOf('※ 検算したところ、資料の記述と計算結果が一致しない箇所がありました。');
  const redundantNote = noteAt >= 0 && /一致しません|一致していません|合いません/.test(text.slice(0,noteAt));
  const formatOK = suggestions.length === 2 && new Set(suggestions).size === 2 && suggestions.every(s => [...s].length <= 20 && !['もっと詳しく','もっと簡単に','説明して','他には？','他には?'].includes(s));
  const anchorHits = suggestions.filter(s => c.suggestionAnchors.some(a => s.includes(a))).length;
  return {rubricVersion:VERSION, failures, legacy: legacyFailures === null ? null : {version:'legacy-v1', pass:legacyFailures.length === 0 && !text.includes('[['), failures:legacyFailures},
    gates:Object.fromEntries(GATES.map(g => [g, failures.some(f => f.gate === g) ? 'fail' : 'unscored'])),
    // Heuristics are necessary conditions only; a human must confirm semantic quality.
    autoChecksPass:failures.length === 0, soft:{clarity:null, conciseness:null, suggestions:null},
    diagnostics:{providerCompletion:completion,discrepancyNotePresent:noteAt>=0,redundantDiscrepancyNote:redundantNote,bodyChars:[...text].length, suggestionFormatOK:formatOK, suggestionAnchorHits:anchorHits}};
}
function applyReview(row, review) {
  if (!review) return row;
  if (!review.gates || GATES.some(g => !review.gates[g] || !['pass','fail','unscored'].includes(review.gates[g].status) || typeof review.gates[g].reason !== 'string' || !review.gates[g].reason.trim())) throw Error('INVALID_REVIEW_GATES');
  const gates = Object.fromEntries(GATES.map(g => [g, review.gates[g].status]));
  // Human review may document heuristic false positives; do not erase original diagnostics.
  const soft = {...row.scoring.soft};
  for (const k of ['clarity','conciseness','suggestions']) {
    const v = review.soft?.[k];
    if (v !== undefined && v !== null) { if (!Number.isInteger(v) || v < 0 || v > 2) throw Error('INVALID_SOFT_REVIEW'); soft[k] = v; }
  }
  return {...row, scoring:{...row.scoring, gates, soft}, review};
}
function percentile(values, q) { if (!values.length) return null; const a = [...values].sort((x,y) => x-y); return a[Math.max(0,Math.ceil(a.length*q)-1)]; }
function trialGroups(rows) {
  const m = new Map();
  for (const r of rows) { const k = `${r.caseId}:${r.repeatIndex}`; if (!m.has(k)) m.set(k,[]); m.get(k).push(r); }
  return [...m.values()];
}
function trialStatus(group) {
  if (group.some(r => r.error)) return 'error';
  if (group.some(r => GATES.some(g => r.scoring.gates[g] === 'fail'))) return 'fail';
  if (group.every(r => GATES.every(g => r.scoring.gates[g] === 'pass'))) return 'pass';
  return 'unscored';
}
function summarize(rows) {
  const trials = trialGroups(rows), answered = rows.filter(r => !r.error), costs = rows.map(r => r.metrics?.estimatedCostUSD);
  const knownCosts = costs.filter(v => typeof v === 'number'), first = answered.map(r=>r.metrics.firstVisibleMs).filter(v=>typeof v==='number');
  const complete = answered.map(r=>r.metrics.completionMs).filter(v=>typeof v==='number');
  return {trials:trials.length, turns:rows.length, trialStatus:Object.fromEntries(['pass','fail','unscored','error'].map(s => [s,trials.filter(g=>trialStatus(g)===s).length])),
    verifiedPassRate:trials.length ? trials.filter(g=>trialStatus(g)==='pass').length/trials.length : null,
    failureRate:trials.length ? trials.filter(g=>trialStatus(g)==='fail').length/trials.length : null,
    unscoredTrials:trials.filter(g=>trialStatus(g)==='unscored').length,
    soft:Object.fromEntries(['clarity','conciseness','suggestions'].map(k=>{const a=answered.map(r=>r.scoring.soft[k]).filter(v=>typeof v==='number');return [k,{mean:a.length?a.reduce((x,y)=>x+y,0)/a.length:null,n:a.length}];})),
    suggestionDiagnostics:{formatPassedTurns:answered.filter(r=>r.scoring.diagnostics.suggestionFormatOK).length,checkedTurns:answered.length,anchorHits:answered.reduce((n,r)=>n+r.scoring.diagnostics.suggestionAnchorHits,0)},
    autoChecksPassedTrials:trials.filter(g => g.every(r => !r.error && r.scoring.autoChecksPass)).length,
    legacy:{passedTurns:answered.filter(r=>r.scoring.legacy?.pass).length, scoredTurns:answered.filter(r=>r.scoring.legacy).length},
    gates:Object.fromEntries(GATES.map(g => [g,Object.fromEntries(['pass','fail','unscored'].map(s => [s,answered.filter(r=>r.scoring.gates[g]===s).length]))])),
    discrepancyNotes:{presentTurns:answered.filter(r=>r.scoring.diagnostics.discrepancyNotePresent).length,redundantTurns:answered.filter(r=>r.scoring.diagnostics.redundantDiscrepancyNote).length},
    executionErrors:rows.filter(r=>r.error).length,
    errorsByCategory:Object.fromEntries([...new Set(rows.filter(r=>r.error).map(r=>r.error.category||'unknown'))].map(c=>[c,rows.filter(r=>r.error&&(r.error.category||'unknown')===c).length])),
    apiErrors:rows.filter(r=>r.error).length, // legacy field: includes identity/output errors too
    firstVisibleMs:{p50:percentile(first,.5),p95:percentile(first,.95),n:first.length}, completionMs:{p50:percentile(complete,.5),p95:percentile(complete,.95),n:complete.length},
    cost:{knownTotalUSD:knownCosts.length ? knownCosts.reduce((a,b)=>a+b,0) : null, knownMeanUSD:knownCosts.length ? knownCosts.reduce((a,b)=>a+b,0)/knownCosts.length : null, unknownTurns:costs.length-knownCosts.length},
    perCase:Object.fromEntries([...new Set(rows.map(r=>r.caseId))].map(id => {const t=trials.filter(g=>g[0].caseId===id);return [id,{trials:t.length,passed:t.filter(g=>trialStatus(g)==='pass').length,failed:t.filter(g=>trialStatus(g)==='fail').length,errors:t.filter(g=>trialStatus(g)==='error').length,unscored:t.filter(g=>trialStatus(g)==='unscored').length}];}))};
}
function readRun(dir, reviewsFile) {
  const manifest = JSON.parse(fs.readFileSync(path.join(dir,'manifest.json'),'utf8'));
  let rows = fs.readFileSync(path.join(dir,'results.jsonl'),'utf8').trim().split('\n').filter(Boolean).map(s=>JSON.parse(s));
  if (reviewsFile) {
    const reviews=JSON.parse(fs.readFileSync(reviewsFile,'utf8'));
    if (reviews.runId !== manifest.runId || !Array.isArray(reviews.entries)) throw Error('REVIEW_RUN_MISMATCH');
    const seen = new Set();
    for (const r of reviews.entries) { if (seen.has(r.rowId) || !rows.some(x=>x.rowId===r.rowId && !x.error)) throw Error('INVALID_REVIEW_ROW'); seen.add(r.rowId); }
    rows = rows.map(r=>applyReview(r,reviews.entries.find(x=>x.rowId===r.rowId)));
  }
  return {manifest, rows, summary:summarize(rows)};
}
function compare(before, after) {
  for (const key of ['datasetHash','rubricVersion','scoringHash','split','repeat','transport','fixtureHash','generationConfigHash']) if (before.manifest[key] !== after.manifest[key]) throw Error(`INCOMPARABLE_${key}`);
  if (!before.manifest.complete || !after.manifest.complete || before.rows.length !== after.rows.length) throw Error('INCOMPLETE_RUN');
  const beforeIDs=before.rows.map(r=>r.rowId).sort(), afterIDs=after.rows.map(r=>r.rowId).sort();
  if (canonical(beforeIDs)!==canonical(afterIDs)) throw Error('INCOMPARABLE_ROWS');
  const caseIds=Object.keys(before.summary.perCase);
  const gateRegressions=[];
  for(const caseId of caseIds)for(const gate of GATES){
    const fails=run=>run.rows.filter(r=>r.caseId===caseId&&!r.error&&r.scoring.gates[gate]==='fail').length;
    const b=fails(before),a=fails(after);if(a>b)gateRegressions.push({caseId,gate,beforeFailures:b,afterFailures:a});
  }
  // A changed model is visible, but is a legitimate experiment; no hidden matching.
  return {before:before.summary,after:after.summary,model:{before:before.manifest.model,after:after.manifest.model},
    gateRegressions,
    regressions:caseIds.filter(id => gateRegressions.some(g=>g.caseId===id) || after.summary.perCase[id].failed > before.summary.perCase[id].failed || after.summary.perCase[id].errors > before.summary.perCase[id].errors || after.summary.perCase[id].passed < before.summary.perCase[id].passed),
    note:'自動チェックは必要条件のみ。unscoredは品質合格ではない。実行順・ネットワーク差も遅延へ影響する。'};
}
module.exports={GATES,VERSION,scoringHash,sameVisible,hash,canonical,norm,validateCase,loadCases,score,applyReview,summarize,readRun,compare};
