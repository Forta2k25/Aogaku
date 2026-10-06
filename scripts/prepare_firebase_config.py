#!/usr/bin/env python3
"""Local build step only. Never calls Firebase or Google Cloud."""
import json
import os
import plistlib
from pathlib import Path

root = Path(os.environ['SRCROOT'])
destination = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']
destination.mkdir(parents=True, exist_ok=True)
debug = os.environ['CONFIGURATION'] == 'Debug'
role = 'development' if debug else 'production'
production = root / 'Aogaku/GoogleService-Info.plist'
protected_id = plistlib.loads(production.read_bytes())['PROJECT_ID']
for name in ['GoogleService-Info.plist', 'GoogleService-Info-development.plist', 'GoogleService-Info-production.plist', 'FirebaseEnvironment.plist']:
    (destination / name).unlink(missing_ok=True)
source = root / f'Config/Firebase/{role.capitalize()}/GoogleService-Info.plist'
if not debug and not source.exists():
    source = production  # Existing local production file; never used by Debug.
manifest = {'role': role}
if source.exists():
    config = plistlib.loads(source.read_bytes())
    project = config.get('PROJECT_ID')
    if debug:
        settings_path = root / 'Config/firebase-development.json'
        if not settings_path.exists():
            raise SystemExit('Development configuration requires Config/firebase-development.json')
        settings = json.loads(settings_path.read_text())
        if not project or project == protected_id or settings.get('projectId') != project:
            raise SystemExit('Development project mismatch or protected production project: build stopped')
    elif project != protected_id:
        raise SystemExit('Release requires the original production project: build stopped')
    if config.get('BUNDLE_ID') != os.environ['PRODUCT_BUNDLE_IDENTIFIER']:
        raise SystemExit('Firebase BUNDLE_ID differs from the selected build target')
    manifest['projectID'] = project
    (destination / f'GoogleService-Info-{role}.plist').write_bytes(plistlib.dumps(config))
elif not debug:
    raise SystemExit('Production configuration is missing')
(destination / 'FirebaseEnvironment.plist').write_bytes(plistlib.dumps(manifest))
print(f'Firebase config: {role}; supplied={source.exists()}; no network operation')
