#!/usr/bin/env node
'use strict';
const fs=require('node:fs'),path=require('node:path');
const {VERSION,scoringHash,sameVisible,readRun,score,summarize}=require('./tutor-eval/core.cjs');
function rescore(input,output) {
 if(!input||!output||fs.existsSync(output))throw Error('INVALID_RESCORE_PATH');
 const original=readRun(input),cases=JSON.parse(fs.readFileSync(path.join(input,'cases.json'),'utf8'));
 const rows=original.rows.map(row=>{
  if(row.error)return row;
  if(typeof row.visibleText!=='string')throw Error('VISIBLE_STREAM_NOT_SAVED');
  const c=cases.find(c=>c.id===row.caseId);if(!c)throw Error('CASE_NOT_FOUND');
  const scoring=score(c,{text:row.text,suggestions:row.suggestions,provider:row.provider});
  if(!sameVisible(row.visibleText,row.text)){scoring.failures.push({gate:'grounding',category:'stream',reason:'表示されたstreamと保存本文が不一致'});scoring.autoChecksPass=false;scoring.gates.grounding='fail';}
  const {review,...unreviewed}=row;return {...unreviewed,scoring};
 });
 const manifest={...original.manifest,runId:path.basename(path.resolve(output)),rescoredFrom:original.manifest.runId,rescoredAt:new Date().toISOString(),rubricVersion:VERSION,scoringHash:scoringHash()};
 fs.mkdirSync(output,{recursive:true,mode:0o700});
 fs.writeFileSync(path.join(output,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
 fs.writeFileSync(path.join(output,'cases.json'),JSON.stringify(cases,null,2)+'\n');
 fs.writeFileSync(path.join(output,'results.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
 const summary=summarize(rows);fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify(summary,null,2)+'\n');
 return summary;
}
if(require.main===module){try{if(process.argv.length!==4)throw Error('USAGE: node scripts/tutor_eval_rescore.cjs INPUT OUTPUT');console.log(JSON.stringify(rescore(process.argv[2],process.argv[3]),null,2));}catch(e){console.error(e.message);process.exitCode=1;}}
module.exports={rescore};
