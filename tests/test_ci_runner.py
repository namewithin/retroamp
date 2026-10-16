import importlib.util
from pathlib import Path
import unittest

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


if __name__ == '__main__':
    unittest.main()
