#!/usr/bin/env node
'use strict';
const {readRun,compare}=require('./tutor-eval/core.cjs');
function main(args) {
  if(args.length<2)throw Error('USAGE: node scripts/tutor_eval_compare.cjs BEFORE AFTER [BEFORE_REVIEW AFTER_REVIEW]');
  if(![2,4].includes(args.length))throw Error('INVALID_ARGUMENT');
  const result=compare(readRun(args[0],args[2]),readRun(args[1],args[3]));
  console.log(JSON.stringify(result,null,2));
  return result.regressions.length?2:0;
}
if(require.main===module){try{process.exitCode=main(process.argv.slice(2));}catch(e){console.error(e.message);process.exitCode=1;}}
module.exports={main};
