#!/usr/bin/env python3
"""Operator-only interactive login; no signup/reset/IAM or token output."""
import base64, getpass, json, os, pathlib, plistlib, sys, time, urllib.request, urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/production-phase5a'

def main():
    operator = json.loads((OUT / 'operator.json').read_text())
    assert operator['projectId'] == 'forta-aogaku' and len(operator['allowedUIDs']) == 1
    with (ROOT / 'Aogaku/GoogleService-Info.plist').open('rb') as f:
        config = plistlib.load(f)
    assert config['PROJECT_ID'] == 'forta-aogaku' and str(config['GCM_SENDER_ID']) == '505828754933'
    assert config['BUNDLE_ID'] == 'com.forta2k25.Aogaku' and config['STORAGE_BUCKET'] == 'forta-aogaku.firebasestorage.app'
    print('指定済み内部UIDのEmail/Passwordでログインします。新規登録・パスワード変更は行いません。')
    email = getpass.getpass('Firebaseログインemail（非表示）: ').strip()
    password = getpass.getpass('Firebaseログインpassword（非表示）: ')
    body = json.dumps({'email': email, 'password': password, 'returnSecureToken': True}).encode()
    req = urllib.request.Request('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + config['API_KEY'], data=body, headers={'Content-Type': 'application/json'}, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        print('Firebase login failed: HTTP ' + str(error.code) + '。メール・パスワードを確認してください。', file=sys.stderr)
        return 1
    del email, password, body
    assert result['localId'] == operator['allowedUIDs'][0], 'STOP: authenticated UID does not match approved internal UID'
    encoded = result['idToken'].split('.')[1]
    claims = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
    assert claims['aud'] == 'forta-aogaku' and claims['iss'] == 'https://securetoken.google.com/forta-aogaku' and claims['sub'] == result['localId']
    OUT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(OUT, 0o700)
    dest = OUT / 'pilot-auth.json'
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump({'idToken': result['idToken'], 'refreshToken': result['refreshToken'], 'expiresAt': time.time() + int(result['expiresIn']), 'projectId': 'forta-aogaku'}, f)
    os.chmod(dest, 0o600)
    print('内部UIDの認証完了。tokenはGit除外のprivateファイルに保存しました。チャットへ貼らないでください。')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('STOP: ' + (str(error) if isinstance(error, AssertionError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
