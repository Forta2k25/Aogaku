'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {GATES,VERSION,sameVisible,norm,loadCases,score,applyReview,summarize,compare}=require('./core.cjs');
const {options}=require('../tutor_eval.cjs');
const root=path.resolve(__dirname,'../../eval/tutor/cases');
const cases=loadCases(root,'dev');const wrong=cases.find(c=>c.id==='legacy-04'),correct=cases.find(c=>c.id==='legacy-05');
const reply=text=>({text,suggestions:['y軸反射の式を検算して','符号の意味は？']});
function row(text,c=wrong){return {rowId:'legacy-04:1:1',caseId:c.id,repeatIndex:1,turnIndex:1,text,scoring:score(c,reply(text)),metrics:{firstVisibleMs:5,completionMs:20,estimatedCostUSD:.01}};}
function review(status='pass'){return {gates:Object.fromEntries(GATES.map(g=>[g,{status,reason:'教材・式と照合済み'}])),soft:{clarity:2,conciseness:1,suggestions:2}};}
test('reject empty, invalid, unknown and mixed split selections',()=>{
 for(const args of [['--repeat','0'],['--repeat','-1'],['--repeat','NaN'],['--repeat','1.5'],['--repeat','31'],['--split','all'],['--unknown'],['--only'],['--model'],['--model','../invalid']])assert.throws(()=>options(args));
 assert.throws(()=>loadCases(root,'dev',['unknown']));assert.throws(()=>loadCases(root,'dev',['holdout-discount']));
 assert.equal(loadCases(root,'dev',['legacy-04']).length,1);
});
test('family leakage is rejected before evaluation',()=>{
 const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'tutor-cases-'));
 try{for(const split of ['dev','holdout']){fs.mkdirSync(path.join(tmp,split));fs.writeFileSync(path.join(tmp,split,'case.json'),JSON.stringify({...wrong,id:split+'-case',split}));}assert.throws(()=>loadCases(tmp,'dev'),/SPLIT_FAMILY_LEAKAGE/);}finally{fs.rmSync(tmp,{recursive:true});}
});
test('math normalization preserves signs and removes left/right before slashes',()=>{
 assert.equal(norm('$$2f\\left(−3x − 1\\right)$$'), '2f(-3x-1)');
 assert.equal(norm('sin(x²)+C'),'sin(x^2)+C');
 assert.equal(norm('60x \\leq 300'),'60x<=300');assert.notEqual(norm('2f(-3x-1)'),norm('2f(-3x+1)'));
});
test('wrong formula, missing source formula and marker leaks fail necessary checks',()=>{
 for(const text of ['ただし資料は2f(-3x+1)です。','正解は2f(-3x-1)です。','[[作業]]資料2f(-3x+1)、計算2f(-3x-1)'])assert.equal(score(wrong,reply(text)).autoChecksPass,false);
});
test('a response containing both equations is still unscored until semantic review',()=>{
 const s=score(wrong,reply('資料2f(-3x+1)、計算2f(-3x-1)。ただしどちらも正しいです。'));
 assert.equal(s.autoChecksPass,true);assert(GATES.every(g=>s.gates[g]==='unscored'));
 const r=applyReview(row('資料2f(-3x+1)、計算2f(-3x-1)。ただしどちらも正しいです。'),review('fail'));
 assert.equal(summarize([r]).trialStatus.fail,1);
});
test('empty response no longer passes the correct-source control',()=>{
 assert.equal(score(correct,reply('普通に説明します。')).autoChecksPass,false);
 assert.equal(score(correct,reply('普通に説明します。')).legacy.pass,true);
});
test('suggestions report format and anchors without inventing semantic scores',()=>{
 const s=score(wrong,{text:'資料2f(-3x+1)、正解2f(-3x-1)',suggestions:['もっと詳しく','もっと詳しく']});
 assert.equal(s.diagnostics.suggestionFormatOK,false);assert.equal(s.soft.suggestions,null);
});
test('manual review requires gate-specific evidence and bounded soft scores',()=>{
 assert.throws(()=>applyReview(row('x'),{gates:{}}));
 assert.throws(()=>applyReview(row('x'),{...review(),soft:{clarity:3}}));
 const x=applyReview(row('資料2f(-3x+1)、正解2f(-3x-1)'),review());assert.equal(summarize([x]).trialStatus.pass,1);
});
test('multi-turn is successful only if all actual turns are reviewed and pass',()=>{
 const a=applyReview(row('資料2f(-3x+1)、正解2f(-3x-1)'),review());
 const b={...a,rowId:'legacy-04:1:2',turnIndex:2,scoring:{...a.scoring,gates:{...a.scoring.gates,correctness:'fail'}}};
 const s=summarize([a,b]);assert.equal(s.trials,1);assert.equal(s.turns,2);assert.equal(s.trialStatus.fail,1);
});
test('unknown costs and provider errors remain separate from quality failure',()=>{
 const s=summarize([{rowId:'x:1:1',caseId:'x',repeatIndex:1,error:{code:'CHAT_UNAVAILABLE'},metrics:{estimatedCostUSD:null}}]);
 assert.equal(s.cost.knownTotalUSD,null);assert.equal(s.cost.unknownTurns,1);assert.equal(s.trialStatus.error,1);assert.equal(s.trialStatus.fail,0);
});
test('comparisons refuse different data, rubric, transport, repeats and incomplete runs',()=>{
 const rows=[row('資料2f(-3x+1)、正解2f(-3x-1)')];
 const m={complete:true,datasetHash:'a',rubricVersion:VERSION,scoringHash:'s',split:'dev',repeat:1,transport:'stream',fixtureHash:'x',generationConfigHash:'g',model:'m'};
 const run={manifest:m,rows,summary:summarize(rows)};
 assert.equal(compare(run,run).regressions.length,0);
 for(const k of ['datasetHash','rubricVersion','scoringHash','split','repeat','transport','fixtureHash','generationConfigHash'])assert.throws(()=>compare(run,{...run,manifest:{...m,[k]:'different'}}));
 assert.throws(()=>compare(run,{...run,manifest:{...m,complete:false}}));
});

test('visible stream ignores extra blank lines but detects missing content',()=>{assert(sameVisible('a\n\n\n\nb','a\n\nb'));assert(!sameVisible('答え1','答え2'));assert(!sameVisible('答え1[[次]]候補','答え1'));});
test('duplicate disclaimer is a soft diagnostic, not an invented correctness failure',()=>{
 const c=cases.find(c=>c.id==='dev-integral');
 const s=score(c,reply('sin(x^2)+Cです。資料とは一致しません。\n※ 検算したところ、資料の記述と計算結果が一致しない箇所がありました。'));
 assert.equal(s.diagnostics.redundantDiscrepancyNote,true);assert.equal(s.gates.correctness,'unscored');
 assert.equal(score(c,reply('sin(x^2)+Cです。資料とは一致しません。')).diagnostics.redundantDiscrepancyNote,false);
});
test('LaTeX unit wrappers do not turn a correct unit conversion into a failed check',()=>{
 assert.equal(norm('20 \\text{ m/s}'),'20m/s');
 assert.equal(norm('20 \\mathrm{m/s}'),'20m/s');
 const c=loadCases(root,'dev',['dev-known-units'])[0];assert.equal(score(c,reply('正しくは20 \\text{m/s}です。')).autoChecksPass,true);
});

test('model selection is explicit and accepts only Gemini model names',()=>{assert.equal(options(['--model','gemini-3.5-flash']).model,'gemini-3.5-flash');});
test('selecting measured cases preserves provenance and refuses mixed or ambiguous runs',()=>{
 const {select}=require('../tutor_eval_select.cjs');
 const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'tutor-select-test-'));
 try{
  const manifest={runId:'source-a',complete:true,sourceHash:'s',promptHash:'p',model:'m',generationConfigHash:'g',repeat:1,transport:'stream',scoringHash:'r',rubricVersion:VERSION,split:'dev',caseIds:[wrong.id],sources:[{caseId:wrong.id,images:[]}]};
  const a=path.join(tmp,'a');fs.mkdirSync(a);fs.writeFileSync(path.join(a,'manifest.json'),JSON.stringify(manifest));fs.writeFileSync(path.join(a,'cases.json'),JSON.stringify([wrong]));fs.writeFileSync(path.join(a,'results.jsonl'),JSON.stringify(row('資料2f(-3x+1)、正解2f(-3x-1)'))+'\n');
  const out=path.join(tmp,'selected');select(out,[wrong.id],[a]);const selected=JSON.parse(fs.readFileSync(path.join(out,'manifest.json')));assert.equal(selected.selectedFrom[0].runId,'source-a');assert.equal(selected.expectedTurns,1);
  assert.throws(()=>select(path.join(tmp,'missing'),['no-such-case'],[a]));assert.throws(()=>select(path.join(tmp,'duplicate'),[wrong.id],[a,a]));
  const b=path.join(tmp,'b');fs.cpSync(a,b,{recursive:true});fs.writeFileSync(path.join(b,'manifest.json'),JSON.stringify({...manifest,model:'other'}));assert.throws(()=>select(path.join(tmp,'mixed'),[wrong.id],[a,b]),/MIXED_model/);
 }finally{fs.rmSync(tmp,{recursive:true,force:true});}
});
test('known incomplete provider output fails completion even when the answer has every keyword',()=>{
 const c=cases.find(c=>c.id==='dev-derivative');const r={...reply('正しくはe^x(1+x)です。'),provider:{finishReasons:['MAX_TOKENS']}};
 const s=score(c,r);assert.equal(s.gates.task_completion,'fail');assert.equal(s.diagnostics.providerCompletion,'incomplete');
 const good=score(c,{...r,provider:{finishReasons:['STOP']}});assert.equal(good.diagnostics.providerCompletion,'confirmed');assert.equal(good.gates.task_completion,'unscored');
 assert.equal(score(c,reply('e^x(1+x)')).diagnostics.providerCompletion,'unobserved');
});
test('equal overall pass counts must not hide a new correctness failure',()=>{
 const base=applyReview(row('資料2f(-3x+1)、正解2f(-3x-1)'),review());
 const b={...base,scoring:{...base.scoring,gates:{...base.scoring.gates,task_completion:'fail'}}};
 const a={...base,scoring:{...base.scoring,gates:{...base.scoring.gates,correctness:'fail'}}};
 const manifest={complete:true,repeat:1,model:'m'};
 const result=compare({manifest,rows:[b],summary:summarize([b])},{manifest,rows:[a],summary:summarize([a])});
 assert.deepEqual(result.regressions,[base.caseId]);assert.equal(result.gateRegressions[0].gate,'correctness');assert.equal(result.before.trialStatus.fail,result.after.trialStatus.fail);
});
