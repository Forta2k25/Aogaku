#!/usr/bin/env node
// Dev-only REST tooling. Uses the existing Firebase CLI login in memory; never writes an ADC key.
const {execFileSync} = require('node:child_process');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const ROOT = join(__dirname, '..');
const PROJECT = 'forta-aogaku-dev';
const NUMBER = '1064661805206';
const BUCKET = `${PROJECT}.firebasestorage.app`;
const REGION = 'asia-northeast1';
const APIs = ['firebase.googleapis.com', 'identitytoolkit.googleapis.com', 'firestore.googleapis.com',
  'firebaserules.googleapis.com', 'storage.googleapis.com', 'cloudfunctions.googleapis.com',
  'run.googleapis.com', 'cloudtasks.googleapis.com', 'cloudscheduler.googleapis.com',
  'secretmanager.googleapis.com', 'vision.googleapis.com', 'iamcredentials.googleapis.com',
  'iam.googleapis.com', 'eventarc.googleapis.com', 'pubsub.googleapis.com', 'cloudbuild.googleapis.com',
  'artifactregistry.googleapis.com', 'logging.googleapis.com'];
function guard() {
  const project = execFileSync('python3', ['-c', 'import sys;sys.path.insert(0,"scripts");from firebase_dev import validate_approved;print(validate_approved())'], {cwd: ROOT, encoding: 'utf8'}).trim();
  const manifest = JSON.parse(readFileSync(join(ROOT, 'Config/firebase-development.json')));
  if (project !== PROJECT || manifest.projectNumber !== NUMBER || manifest.storageBucket !== BUCKET) throw Error('STOP: approved Dev identity mismatch');
}
let bearer;
async function token() {
  guard();
  if (bearer) return bearer;
  const lib = process.env.FIREBASE_TOOLS_LIB || join(execFileSync('npm', ['root', '-g'], {encoding:'utf8'}).trim(), 'firebase-tools/lib');
  const account = require(join(lib, 'auth.js')).getGlobalDefaultAccount();
  if (!account?.tokens?.refresh_token) throw Error('Firebase CLI login required');
  const api = require(join(lib, 'api.js'));
  const response = await fetch('https://oauth2.googleapis.com/token', {method:'POST', body: new URLSearchParams({
    client_id: api.clientId(), client_secret: api.clientSecret(), refresh_token: account.tokens.refresh_token,
    grant_type:'refresh_token', scope:'https://www.googleapis.com/auth/cloud-platform'
  })});
  const data = await response.json();
  if (!response.ok || !data.access_token) throw Error(`Firebase login refresh failed (HTTP ${response.status}, ${data.error || 'no token'}); reauthenticate locally`);
  bearer = data.access_token;
  return bearer;
}
function assertURL(url, body) {
  const u = new URL(url);
  const hosts = APIs.concat(['cloudresourcemanager.googleapis.com', 'serviceusage.googleapis.com']);
  if (u.protocol !== 'https:' || !hosts.includes(u.hostname) || u.username || u.password || u.port) throw Error('STOP: unexpected API host');
  const path = decodeURIComponent(u.pathname);
  if (u.hostname === 'logging.googleapis.com' && path === '/v2/entries:list') {
    if (JSON.stringify(body?.resourceNames) !== JSON.stringify([`projects/${PROJECT}`])) throw Error('STOP: log resources must be exactly Dev');
    return;
  }
  const projectScoped = path.match(/^\/v[12](?:beta\d?)?\/projects\/([^/:]+)(?:[/:]|$)/);
  const bucketScoped = u.hostname === 'storage.googleapis.com' && path.startsWith(`/storage/v1/b/${BUCKET}`) && [undefined, '/'].includes(path[`/storage/v1/b/${BUCKET}`.length]);
  const storageAgent = u.hostname === 'storage.googleapis.com' && path === `/storage/v1/projects/${PROJECT}/serviceAccount`;
  if (!(projectScoped && [PROJECT, NUMBER].includes(projectScoped[1])) && !bucketScoped && !storageAgent) throw Error('STOP: API path is not the approved Dev project');
  if (/\/versions\/[^/]+:access$/.test(path)) throw Error('STOP: secret payload reads are disabled');
}
async function request(url, method='GET', body) {
  guard(); assertURL(url, body);
  const r = await fetch(url, {method, headers:{Authorization:`Bearer ${await token()}`, 'Content-Type':'application/json'}, ...(body === undefined ? {} : {body:JSON.stringify(body)})});
  const value = await r.json().catch(() => ({}));
  if (!r.ok) {
    const error = Error(`${new URL(url).hostname}: HTTP ${r.status} ${value.error?.status || ''} ${(value.error?.message || '').slice(0,500)}`);
    error.httpStatus = r.status;
    throw error;
  }
  return value;
}
async function inspect() {
  const project = await request(`https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT}`);
  if (project.projectId !== PROJECT || project.projectNumber !== NUMBER) throw Error('STOP: server project identity mismatch');
  console.log(JSON.stringify({projectId:project.projectId, projectNumber:project.projectNumber, lifecycleState:project.lifecycleState}));
  const results = await Promise.allSettled([
    request(`https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)`),
    request(`https://storage.googleapis.com/storage/v1/b/${BUCKET}`),
    request(`https://serviceusage.googleapis.com/v1/projects/${NUMBER}/services?filter=state:ENABLED&pageSize=200`),
    request(`https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/GROQ_API_KEY`)
  ]);
  for (let i=0; i<results.length; i++) {
    const v=results[i];
    if (v.status==='rejected') console.log(['firestore','bucket','APIs','Groq secret'][i]+': '+v.reason.message);
    else if(i===0) console.log(JSON.stringify({database:v.value.name, location:v.value.locationId}));
    else if(i===1) console.log(JSON.stringify({bucket:v.value.name, location:v.value.location}));
    else if(i===2) console.log(JSON.stringify({enabledAPIs:v.value.services.map(s=>s.config.name), nextPageToken:v.value.nextPageToken || null}));
    else console.log(JSON.stringify({secret:v.value.name, replication:v.value.replication}));
  }
}
async function enable() {
  await inspect();
  const operation = await request(`https://serviceusage.googleapis.com/v1/projects/${NUMBER}/services:batchEnable`, 'POST', {serviceIds:APIs});
  // Service Usage operation IDs are globally scoped. Save/print only the operation name, no credentials.
  console.log(JSON.stringify({enableOperation:operation.name, done:operation.done || false}));
}
module.exports = {ROOT, PROJECT, NUMBER, BUCKET, REGION, APIs, guard, request, token, assertURL};
if (require.main === module) {
  const action = process.argv[2];
  (action === 'inspect' ? inspect() : action === 'enable' ? enable() : Promise.reject(Error('Usage: dev_cloud.cjs inspect|enable')))
    .catch(e=>{console.error(e.message);process.exitCode=1;});
}
