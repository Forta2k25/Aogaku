#!/usr/bin/env node
'use strict';
// Select already measured cases without making more model calls. Refuse mixed inputs/configs.
const fs=require('node:fs'),path=require('node:path');
const {hash,canonical,readRun,summarize}=require('./tutor-eval/core.cjs');
function select(output,ids,inputs) {
 if(!output||fs.existsSync(output)||!Array.isArray(ids)||!ids.length||new Set(ids).size!==ids.length||!inputs.length)throw Error('INVALID_SELECTION');
 const sources=inputs.map(dir=>({dir,...readRun(dir)})),first=sources[0].manifest;
 for(const s of sources){if(!s.manifest.complete)throw Error('INCOMPLETE_INPUT');for(const key of ['sourceHash','promptHash','model','generationConfigHash','repeat','transport','scoringHash','rubricVersion','split'])if(s.manifest[key]!==first[key])throw Error('MIXED_'+key);}
 const cases=[],fixtures=[],rows=[];
 for(const id of [...ids].sort()) {
  const found=sources.filter(s=>s.manifest.caseIds.includes(id));if(found.length!==1)throw Error('AMBIGUOUS_OR_MISSING_CASE');
  const src=found[0],allCases=JSON.parse(fs.readFileSync(path.join(src.dir,'cases.json'),'utf8')),c=allCases.find(c=>c.id===id);
  const subset=src.rows.filter(r=>r.caseId===id);
  if(!c||subset.length!==c.questions.length*first.repeat||new Set(subset.map(r=>r.rowId)).size!==subset.length)throw Error('INCOMPLETE_CASE');
  for(let repeatIndex=1;repeatIndex<=first.repeat;repeatIndex++)for(let turnIndex=1;turnIndex<=c.questions.length;turnIndex++)if(!subset.some(r=>r.repeatIndex===repeatIndex&&r.turnIndex===turnIndex))throw Error('MISSING_TURN');
  const fixture=src.manifest.sources.find(s=>s.caseId===id);if(!fixture)throw Error('MISSING_FIXTURE_PROVENANCE');
  cases.push(c);fixtures.push(fixture);rows.push(...subset);
 }
 const manifest={...first,runId:path.basename(path.resolve(output)),selectedFrom:sources.map(s=>({runId:s.manifest.runId,manifestHash:hash(fs.readFileSync(path.join(s.dir,'manifest.json')))})),selectedAt:new Date().toISOString(),selectionHash:hash(fs.readFileSync(__filename)),caseIds:cases.map(c=>c.id),expectedTurns:rows.length,datasetHash:hash(canonical(cases)),fixtureHash:hash(canonical(fixtures)),sources:fixtures};
 fs.mkdirSync(output,{recursive:true,mode:0o700});
 for(const [name,value] of [['manifest.json',manifest],['cases.json',cases],['summary.json',summarize(rows)]])fs.writeFileSync(path.join(output,name),JSON.stringify(value,null,2)+'\n');
 fs.writeFileSync(path.join(output,'results.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
 return summarize(rows);
}
if(require.main===module){try{if(process.argv.length<5)throw Error('USAGE: node scripts/tutor_eval_select.cjs OUT ID,ID RUN [RUN...]');console.log(JSON.stringify(select(process.argv[2],process.argv[3].split(','),process.argv.slice(4)),null,2));}catch(e){console.error(e.message);process.exitCode=1;}}
module.exports={select};
