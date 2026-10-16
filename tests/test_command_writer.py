"""Real pipe regressions; no application, account, audio, or WebKit is started."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class CommandWriterTests(unittest.TestCase):
    def test_stalled_pipe_deadline_queue_bounds_and_final_frames(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix='retroamp-pipe-check-') as temporary:
            executable = Path(temporary) / 'pipe-check'
            build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                                    str(root / 'Sources/StreamLifecycle.swift'),
                                    str(root / 'tests/CommandWriterChecks.swift'), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            checks = json.loads(result.stdout)
            self.assertGreaterEqual(len(checks), 15)
            self.assertTrue(all(value is True for value in checks.values()), checks)
            print(result.stdout.strip())
