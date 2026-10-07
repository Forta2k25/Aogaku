#!/usr/bin/env python3
"""Offline artifact for only the three recovered account deletion handlers."""
import hashlib
import json
import shutil
import subprocess
import zipfile
from datetime import datetime, timezone
from firebase_production import ROOT, check, require

NAMES = ('preDeleteCleanup', 'deleteAccountServerSide', 'onAuthUserDelete')
P = 'forta-aogaku'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def prepare():
    check(P)
    directory = ROOT / 'build/production-phase3b'
    records = {r['name']: r for r in json.loads((directory / 'initial-production-legacy-live.json').read_text())['records']}
    captured = json.loads((directory / 'captured-source.json').read_text())
    before = {}
    for name in NAMES:
        archive = directory / (name + '-original.zip')
        with zipfile.ZipFile(archive) as z:
            files = {n: digest(z.read(n)) for n in z.namelist() if not n.endswith('/')}
        source = captured[name]
        require(files == source['files'], 'STOP: fresh source ZIP mismatch: ' + name)
        require(source['sourceSha256'] == '2304cabbe6917c0f42baf91784488c466e86df570ff23a5679070546151631c5', 'STOP: current Node22 source drift: ' + name)
        require(records[name]['runtime'] == 'nodejs22' and records[name]['updateTime'] == source['updateTime'], 'STOP: fresh Node22 baseline mismatch: ' + name)
        before[name] = {'entrySha256': source['entrySha256'], 'zipSha256': digest(archive.read_bytes()), 'updateTime': source['updateTime'], 'sourceSha256': source['sourceSha256']}
    subprocess.run(['npm', '--prefix', 'functions', 'run', 'build'], cwd=ROOT, check=True)
    out = directory / 'candidate'
    require(not out.exists(), 'STOP: preserve existing candidate artifact')
    for file in ['legacy-account/index.js', 'ai/account-deletion.js', 'ai/databases.js', 'ai/schema.js', 'ai/domain.js']:
        destination = out / 'lib' / file
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'functions/lib' / file, destination)
    # Deployment profile only. Preserve each live SA; never change IAM or Secrets.
    account = out / 'lib/legacy-account/index.js'
    code = account.read_text()
    require("require('../ai/account-deletion')" in code and "require('../ai')" not in code, 'STOP: worker import in deletion artifact')
    require(code.count('serviceAccount: accountRuntime') == 2, 'STOP: runtime profile format changed')
    code = code.replace('serviceAccount: accountRuntime', "serviceAccount: '505828754933-compute@developer.gserviceaccount.com'", 1)
    code = code.replace('serviceAccount: accountRuntime', "serviceAccount: 'forta-aogaku@appspot.gserviceaccount.com'", 1)
    # Preserve the live Gen1 memory/concurrency; only extend cleanup timeout.
    code = code.replace('memory: "512MB", timeoutSeconds: 540, maxInstances: 20', 'memory: "256MB", timeoutSeconds: 540, maxInstances: 3000')
    account.write_text(code)
    (out / 'lib/index.js').write_text("const legacy = require('./legacy-account');\n" + ''.join(f'exports.{n} = legacy.{n};\n' for n in NAMES))
    with zipfile.ZipFile(directory / 'preDeleteCleanup-original.zip') as fresh_source:
        pkg = json.loads(fresh_source.read('package.json'))
        lock_bytes = fresh_source.read('package-lock.json')
    require(pkg['engines'] == {'node': '22'} and set(pkg['dependencies']) == {'firebase-admin', 'firebase-functions'}, 'STOP: dependency drift')
    (out / 'package.json').write_text(json.dumps(pkg, indent=2) + '\n')
    (out / 'package-lock.json').write_bytes(lock_bytes)
    files = sorted(p for p in out.rglob('*') if p.is_file())
    manifest = {str(p.relative_to(out)): digest(p.read_bytes()) for p in files}
    require(len(files) == 8, 'STOP: unexpected artifact files')
    for name in NAMES:
        require(set(manifest) == set(captured[name]['files']), 'STOP: changed source file set')
        for file, sha in manifest.items():
            if file != 'lib/ai/databases.js':
                require(sha == captured[name]['files'][file], 'STOP: unrelated source change: ' + file)
    for p in files:
        if p.suffix == '.js':
            source = p.read_text()
            require('extractors' not in source and 'groqSecret' not in source and ':access' not in source, 'STOP: provider or Secret payload access')
    archive = directory / 'candidate.zip'
    prepared_at = datetime.now(timezone.utc)
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for p in files:
            item = zipfile.ZipInfo(str(p.relative_to(out)), date_time=prepared_at.timetuple()[:6])
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            z.writestr(item, p.read_bytes())
    proof = {'preparedAt': prepared_at.isoformat(), 'names': list(NAMES), 'files': manifest, 'sourceSha256': digest(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()), 'zipSha256': digest(archive.read_bytes()), 'entrySha256': manifest['lib/index.js'], 'before': before, 'newDependencies': False, 'runtime': 'nodejs22', 'runtimeSAPreserved': True, 'secretBindingsPreserved': True, 'phase4Exports': False}
    path = directory / 'artifact.json'
    path.write_text(json.dumps(proof, indent=2) + '\n')
    path.chmod(0o600)
    (out / 'node_modules').symlink_to(ROOT / 'functions/node_modules', target_is_directory=True)
    print('PASS: three deletion exports only; live SAs/Secret bindings preserved; no providers, workers, or new dependencies')

if __name__ == '__main__':
    prepare()
