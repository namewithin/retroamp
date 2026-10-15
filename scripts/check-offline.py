#!/usr/bin/env python3
"""Run the production DSP checks with isolated preferences and no speaker output."""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
app_source = args.app.resolve()
output = args.output.resolve()
output.parent.mkdir(parents=True, exist_ok=True)
# A previous successful run must not satisfy a failed or timed-out invocation.
output.unlink(missing_ok=True)
with tempfile.TemporaryDirectory(prefix='retroamp-offline-') as work:
    app = Path(work) / 'Retroamp Offline QA.app'
    subprocess.run(['ditto', '--norsrc', '--noextattr', str(app_source), str(app)], check=True)
    info = app / 'Contents/Info.plist'
    properties = plistlib.loads(info.read_bytes())
    properties['CFBundleIdentifier'] = 'local.retroamp.qa.ci.offline'
    info.write_bytes(plistlib.dumps(properties))
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', '--deep', str(app)], check=True)
    # This early check path returns before Keychain/service/session startup.
    subprocess.run([str(app / 'Contents/MacOS/Retroamp'), '--quiet', '--check-audio', str(output)], check=True, timeout=60)
    result = json.loads(output.read_text())
    if result.get('passed') is not True:
        raise SystemExit('Native audio checks failed: ' + json.dumps(result, ensure_ascii=False))
    print(json.dumps(result, indent=2, sort_keys=True))
