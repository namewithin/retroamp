import importlib.util
from pathlib import Path
import contextlib
import io
import json
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ci_runner', Path(__file__).resolve().parents[1] / 'scripts/check-offline.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ResultContractTests(unittest.TestCase):
    def test_requires_successful_assertions(self):
        self.assertEqual(runner.validate_result({'passed': True, 'stereo': True, 'gain': True}, 2), 2)

    def test_failed_assertion_cannot_hide_behind_success_summary(self):
        with self.assertRaises(ValueError):
            runner.validate_result({'passed': True, 'stereo': False}, 1)

    def test_empty_or_shortened_suite_is_not_green(self):
        for result in [{'passed': True}, {'passed': True, 'stereo': True}]:
            with self.subTest(result=result), self.assertRaises(ValueError):
                runner.validate_result(result, 2)

    def test_failed_or_malformed_result_is_rejected(self):
        for result in [None, [], {}, {'passed': False}, {'passed': 'true'}, {'passed': True, 'error': 'failed'}]:
            with self.subTest(result=result), self.assertRaises(ValueError):
                runner.validate_result(result, 1)


class CommandTimeoutTests(unittest.TestCase):
    def test_external_command_timeouts_still_write_failure_summary(self):
        for stalled in ['copy', 'sign', 'verify', 'cleanup']:
            with self.subTest(stalled=stalled), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                output = root / 'summary.json'
                # A stale success must never survive a setup/cleanup failure.
                output.write_text('{"passed": true}')
                calls = []

                def run(command, **options):
                    operation = ('copy' if command[0] == 'ditto' else
                                 'verify' if '--verify' in command else
                                 'sign' if command[0] == 'codesign' else
                                 'cleanup' if command[0] == '/usr/bin/defaults' else 'app')
                    calls.append(operation)
                    self.assertGreater(options.get('timeout', 0), 0, operation + ' must be bounded')
                    if operation == stalled:
                        raise subprocess.TimeoutExpired(command, options['timeout'])
                    if operation == 'copy':
                        info = Path(command[-1]) / 'Contents/Info.plist'
                        info.parent.mkdir(parents=True)
                        info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'fixture'}))
                    if operation == 'app':
                        Path(command[-1]).write_text(json.dumps({'passed': True, **{str(i): True for i in range(16)}}))
                    return subprocess.CompletedProcess(command, 0)

                with patch.object(runner.subprocess, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()), \
                        patch('sys.argv', ['check-offline.py', '--app', str(root / 'source.app'), '--output', str(output)]):
                    code = runner.main()
                self.assertEqual(code, 1)
                summary = json.loads(output.read_text())
                self.assertIs(summary['passed'], False)
                self.assertTrue(summary['errors'])
                if stalled in ['sign', 'verify']:
                    self.assertIn('cleanup', calls)
                if stalled == 'cleanup':
                    self.assertEqual(summary['assertions'], {'audio': 16})


if __name__ == '__main__':
    unittest.main()
