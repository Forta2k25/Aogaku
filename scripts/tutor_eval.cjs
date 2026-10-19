#!/usr/bin/env node
'use strict';
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const {execFileSync} = require('node:child_process');
const {GATES,VERSION,scoringHash,sameVisible,hash,canonical,loadCases,score,summarize} = require('./tutor-eval/core.cjs');
const ROOT = path.resolve(__dirname,'..');
function options(args) {
  const o={split:'dev',repeat:1};
  for(let i=0;i<args.length;i++) {
    const k=args[i];
    if(k==='--list') {o.list=true;continue;}
    if(!['--split','--repeat','--only','--fixtures','--out','--model'].includes(k) || !args[i+1] || args[i+1].startsWith('--')) throw Error('INVALID_ARGUMENT');
    o[k.slice(2)]=args[++i];
  }
  o.repeat=Number(o.repeat);
  if(!Number.isSafeInteger(o.repeat)||o.repeat<1||o.repeat>30||!['dev','holdout'].includes(o.split)) throw Error('INVALID_RUN_OPTIONS');
  if(o.model && !/^gemini-[a-zA-Z0-9.-]+$/.test(o.model))throw Error('INVALID_MODEL');
  if(o.only)o.only=o.only.split(',');
  return o;
}
function treeHash(dir) {
  const files=[];
  function walk(d) {for(const e of fs.readdirSync(d,{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name))) {const p=path.join(d,e.name);if(e.isDirectory())walk(p);else files.push([path.relative(dir,p),hash(fs.readFileSync(p))]);}}
  walk(dir); return hash(canonical(files));
}
async function run(args) {
  const o=options(args), cases=loadCases(path.join(ROOT,'eval/tutor/cases'),o.split,o.only);
  if(o.list) {console.log(cases.map(c=>`${c.id}\t${c.tags.join(',')}\t${c.questions.length} turns`).join('\n'));return 0;}
  const key=process.env.GEMINI_API_KEY;if(!key)throw Error('GEMINI_API_KEY_MISSING');
  const fixtureDir=o.fixtures?path.resolve(o.fixtures):path.join(ROOT,'build/tutor-eval/fixtures');
  const sources=cases.map(c=>({caseId:c.id,images:c.images.map(file=>({file,sha256:hash(fs.readFileSync(path.join(fixtureDir,file)))}))}));
  const out=path.resolve(o.out||path.join(ROOT,'build/tutor-eval/runs',new Date().toISOString().replace(/[:.]/g,'-')));
  if(fs.existsSync(out))throw Error('OUTPUT_ALREADY_EXISTS');
  // Compile current source in isolation; never import stale functions/lib or rewrite tracked generated JS.
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'aogaku-tutor-eval-'));
  try {
    execFileSync(path.join(ROOT,'functions/node_modules/.bin/tsc'),['-p',path.join(ROOT,'functions/tsconfig.json'),'--outDir',path.join(temp,'lib')],{stdio:['ignore','pipe','pipe']});
    const chat=require(path.join(temp,'lib/ai/chat.js'));
    // Eval process only: use the same request/parser with an explicitly selected model.
    // chatUsage returns null for unpriced models; never borrow the Lite price.
    const defaultModel=chat.CHAT.model;
    if(o.model)chat.CHAT.model=o.model;
    const git=(args)=>execFileSync('git',args,{cwd:ROOT,encoding:'utf8'}).trim();
    const prompt=chat.buildMessages({mode:'reply',turns:[{role:'user',text:'test'}],images:[],sourceIds:[],materialExpected:false,unreadSources:0},[])[0].content;
    const manifest={schemaVersion:1,runId:path.basename(out),startedAt:new Date().toISOString(),complete:false,commit:git(['rev-parse','HEAD']),dirty:Boolean(git(['status','--porcelain'])),diffHash:hash(git(['diff','HEAD'])),sourceHash:treeHash(path.join(ROOT,'functions/src')),runnerHash:hash(Buffer.concat([fs.readFileSync(__filename),fs.readFileSync(path.join(__dirname,'tutor-eval/core.cjs')),fs.readFileSync(path.join(__dirname,'tutor-eval/legacy.cjs'))])),promptHash:hash(prompt),datasetHash:hash(canonical(cases)),fixtureHash:hash(canonical(sources)),rubricVersion:VERSION,scoringHash:scoringHash(),split:o.split,repeat:o.repeat,transport:'geminiChatStream',model:chat.CHAT.model,defaultModel,modelOverride:chat.CHAT.model!==defaultModel,generationConfigHash:hash(canonical(chat.geminiChatBody([{role:'user',content:'test'}]).generationConfig)),caseIds:cases.map(c=>c.id),sources,expectedTurns:cases.reduce((s,c)=>s+c.questions.length,0)*o.repeat};
    fs.mkdirSync(out,{recursive:true,mode:0o700});
    const save=()=>fs.writeFileSync(path.join(out,'manifest.json'),JSON.stringify(manifest,null,2)+'\n',{mode:0o600});save();
    fs.writeFileSync(path.join(out,'results.jsonl'),'');
    fs.writeFileSync(path.join(out,'cases.json'),JSON.stringify(cases,null,2)+'\n');
    const rows=[];
    experiment: for(const c of cases) for(let repeatIndex=1;repeatIndex<=o.repeat;repeatIndex++) {
      const images=c.images.map(file=>({mime:'image/jpeg',data:fs.readFileSync(path.join(fixtureDir,file)).toString('base64')}));
      const turns=[];
      for(let turnIndex=1;turnIndex<=c.questions.length;turnIndex++) {
        turns.push({role:'user',text:c.questions[turnIndex-1]});
        const input=chat.validateChat({mode:'reply',turns,sourceIds:[],images,materialExpected:true,unreadSources:0});
        const base={rowId:`${c.id}:${repeatIndex}:${turnIndex}`,caseId:c.id,repeatIndex,turnIndex,tags:c.tags};
        const start=Date.now();let visible='',first=null,attempts=0,httpStatus=null,providerMetadata=Promise.resolve(null);
        // Provider error messages can echo input. Keep only HTTP status in eval logs.
        const request=async(url,init)=>{
          attempts++;const res=await fetch(url,init);httpStatus=res.status;
          if(!res.ok)return new Response(JSON.stringify({error:{message:'provider request rejected'}}),{status:res.status});
          // Observe metadata on a tee, never persist the raw SSE text / hidden memo.
          providerMetadata=res.clone().text().then(raw=>{
            const versions=new Set(),finishes=new Set();let usage;
            for(const line of raw.split('\n')){if(!line.startsWith('data:'))continue;let j;try{j=JSON.parse(line.slice(5));}catch{continue;}
              if(typeof j.modelVersion==='string'&&/^(models\/)?gemini-[a-zA-Z0-9.-]+$/.test(j.modelVersion))versions.add(j.modelVersion);
              for(const c of j.candidates||[])if(typeof c.finishReason==='string'&&/^[A-Z_]+$/.test(c.finishReason))finishes.add(c.finishReason);
              if(j.usageMetadata)usage=j.usageMetadata;
            }
            const token=n=>Number.isSafeInteger(n)&&n>=0?n:null;
            return {modelVersions:[...versions],finishReasons:[...finishes],inputTokens:token(usage?.promptTokenCount),outputTokens:token(usage?.candidatesTokenCount),thoughtTokens:token(usage?.thoughtsTokenCount),totalTokens:token(usage?.totalTokenCount)};
          }).catch(()=>null);
          return res;
        };
        let row;
        try {
          const reply=await chat.geminiChatStream(key,chat.buildMessages(input,c.context),delta=>{if(delta&&first===null)first=Date.now()-start;visible+=delta;},request,images);
          const scoring=score(c,{...reply,provider:await providerMetadata});
          if(!sameVisible(visible,reply.text))scoring.failures.push({gate:'grounding',category:'stream',reason:'表示されたstreamと保存本文が不一致'});
          if(!sameVisible(visible,reply.text)){scoring.autoChecksPass=false;scoring.gates.grounding='fail';}
          row={...base,text:reply.text,visibleText:visible,suggestions:reply.suggestions,scoring,metrics:{firstVisibleMs:first,completionMs:Date.now()-start,inputTokens:reply.recognition.inputTokens,outputTokens:reply.recognition.outputTokens,totalTokens:reply.recognition.totalTokens,estimatedCostUSD:reply.recognition.estimatedCostUSD,costUnknownReason:reply.recognition.estimatedCostUSD===null?(chat.CHAT.model!==defaultModel?'unpriced_model':'usage_unavailable'):null,pricingVersion:reply.recognition.pricingVersion,pricingAsOf:reply.recognition.pricingAsOf,attempts,httpStatus}};
          turns.push({role:'assistant',text:reply.text});
        } catch(e) {
          row={...base,error:{category:e.code==='CHAT_MODEL_MISMATCH'?'model_identity':e.code==='CHAT_INVALID_RESULT'?'provider_output':'transport',code:/^[A-Z_]+$/.test(e.code||'')?e.code:'EVAL_REQUEST_FAILED',httpStatus},metrics:{firstVisibleMs:first,completionMs:Date.now()-start,estimatedCostUSD:null,attempts}};
        }
        row.provider=await providerMetadata;
        rows.push(row);fs.appendFileSync(path.join(out,'results.jsonl'),JSON.stringify(row)+'\n');
        console.log(`${row.error?'ERROR':row.scoring.autoChecksPass?'AUTO_OK (review pending)':'CHECK_FAIL'} ${row.rowId} ${row.metrics.completionMs}ms`);
        if(row.error){
          // Configuration/identity cannot recover by spending more calls on other cases.
          if(row.error.category==='model_identity'||[400,401,403,404].includes(row.error.httpStatus)){manifest.abortReason=row.error.code;break experiment;}
          break; // Never manufacture assistant turns after a failed request.
        }
      }
    }
    manifest.complete=rows.length===manifest.expectedTurns;manifest.finishedAt=new Date().toISOString();save();
    const summary=summarize(rows);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(summary,null,2)+'\n');
    const review={runId:manifest.runId,entries:rows.filter(r=>!r.error).map(r=>({rowId:r.rowId,gates:Object.fromEntries(GATES.map(g=>[g,{status:'unscored',reason:'未確認：cases.jsonのrubricと照合する'}])),soft:{clarity:null,conciseness:null,suggestions:null}}))};
    fs.writeFileSync(path.join(out,'review-template.json'),JSON.stringify(review,null,2)+'\n');
    console.log(JSON.stringify({out,summary},null,2));
    return rows.some(r=>r.error||!r.scoring.autoChecksPass)?2:0;
  } finally {fs.rmSync(temp,{recursive:true,force:true});}
}
if(require.main===module)run(process.argv.slice(2)).then(code=>{process.exitCode=code;}).catch(()=>{console.error('評価を開始/完了できません。引数・fixture・APIキー・TypeScript環境を確認してください（秘密を含む可能性のある例外詳細は非表示）。');process.exitCode=1;});
module.exports={options,run};
