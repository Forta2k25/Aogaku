#!/usr/bin/env node
'use strict';
const {readRun}=require('./tutor-eval/core.cjs');
if(process.argv.length!==4){console.error('Usage: node scripts/tutor_eval_review.cjs RUN REVIEW');process.exitCode=1;}
else try{console.log(JSON.stringify(readRun(process.argv[2],process.argv[3]).summary,null,2));}catch(e){console.error(e.message);process.exitCode=1;}
