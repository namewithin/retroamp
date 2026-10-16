#!/usr/bin/env python3
"""Run isolated, silent app regressions without Google or system-audio capture."""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import uuid

SUITES = {
    'audio': ('--check-audio', 16),
    'session': ('--check-session-storage', 13),
    'library': ('--check-v09', 40),
}


def validate_result(result, minimum):
    if not isinstance(result, dict) or result.get('passed') is not True:
        raise ValueError('Check did not report passed=true')
    assertions = {key: value for key, value in result.items() if key != 'passed'}
    failed = [key for key, value in assertions.items() if value is not True]
    if failed or len(assertions) < minimum:
        raise ValueError(f'Expected at least {minimum} successful assertions; got {len(assertions)}, failed: {failed}')
    return len(assertions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--suite', choices=[*SUITES, 'all'], default='audio')
    args = parser.parse_args()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)  # Never reuse a prior successful summary.
    evidence = output.parent / (output.stem + '-suites')
    evidence.mkdir(exist_ok=True)
    names = list(SUITES) if args.suite == 'all' else [args.suite]
    results = {}
    counts = {}
    errors = {}
    try:
        with tempfile.TemporaryDirectory(prefix='retroamp-offline-') as work:
            app = Path(work) / 'Retroamp Offline QA.app'
            subprocess.run(['ditto', '--norsrc', '--noextattr', str(args.app.resolve()), str(app)], check=True, timeout=60)
            for name in names:
                flag, minimum = SUITES[name]
                directory = evidence / name
                directory.mkdir(exist_ok=True)
                result_path = directory / 'result.json'
                result_path.unlink(missing_ok=True)
                identifier = 'local.retroamp.qa.ci.' + name + '.' + uuid.uuid4().hex
                try:
                    # Each suite gets fresh preferences, never the personal app's library.
                    info = app / 'Contents/Info.plist'
                    properties = plistlib.loads(info.read_bytes())
                    properties['CFBundleIdentifier'] = identifier
                    info.write_bytes(plistlib.dumps(properties))
                    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True, timeout=60)
                    subprocess.run(['codesign', '--verify', '--strict', '--deep', str(app)], check=True, timeout=60)
                    # These flags return before personal Keychain/service/session startup.
                    with (directory / 'app.log').open('w') as log:
                        subprocess.run([str(app / 'Contents/MacOS/Retroamp'), '--quiet', flag, str(result_path)],
                                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
                    results[name] = json.loads(result_path.read_text())
                    counts[name] = validate_result(results[name], minimum)
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    errors[name] = str(error)
                finally:
                    # Only this generated test preference domain can be removed.
                    try:
                        subprocess.run(['/usr/bin/defaults', 'delete', identifier], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, timeout=10)
                    except (OSError, subprocess.SubprocessError) as error:
                        errors[name] = (errors.get(name, '') + '; preference cleanup: ' + str(error)).lstrip('; ')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        errors['setup'] = str(error)
    summary = {'passed': not errors and len(counts) == len(names), 'assertions': counts, 'errors': errors}
    # Keep the original single-suite result format for existing local commands.
    document = results[names[0]] if len(names) == 1 and summary['passed'] else summary
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + '\n')
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
