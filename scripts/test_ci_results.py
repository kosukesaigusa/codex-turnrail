"""Allow only planned Engine skips without weakening other required checks."""

import copy
import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import check_ci_results


def needs_data(required):
    needs = {name: {"result": "success"} for name in check_ci_results.REQUIRED}
    needs["changes"]["outputs"] = {"engine_required": str(required).lower()}
    needs.update(
        {
            name: {"result": "success" if required else "skipped"}
            for name in check_ci_results.ENGINE
        }
    )
    return needs


def check(needs):
    with (
        patch.dict(check_ci_results.os.environ, {"NEEDS": json.dumps(needs)}),
        redirect_stdout(io.StringIO()),
    ):
        check_ci_results.main()


class CiResultsTests(unittest.TestCase):
    def test_required_engine_success_and_explicitly_planned_skip_pass(self):
        check(needs_data(True))
        check(needs_data(False))

    def test_failure_cancellation_and_unplanned_skips_never_pass(self):
        for required in (True, False):
            expected = needs_data(required)
            for job in expected:
                for status in ("success", "failure", "cancelled", "skipped", "neutral"):
                    if status == expected[job]["result"]:
                        continue
                    with (
                        self.subTest(required=required, job=job, status=status),
                        self.assertRaises(SystemExit),
                    ):
                        needs = copy.deepcopy(expected)
                        needs[job]["result"] = status
                        check(needs)

    def test_missing_unexpected_and_invalid_plan_data_fail(self):
        for name in check_ci_results.REQUIRED | check_ci_results.ENGINE:
            needs = needs_data(False)
            del needs[name]
            with self.subTest(missing=name), self.assertRaises(SystemExit):
                check(needs)
        needs = needs_data(False)
        needs["extra"] = {"result": "success"}
        with self.assertRaises(SystemExit):
            check(needs)
        for value in ("", "False", None, False):
            needs = needs_data(False)
            needs["changes"]["outputs"]["engine_required"] = value
            with self.subTest(value=value), self.assertRaises(SystemExit):
                check(needs)
        needs = needs_data(False)
        needs["changes"]["outputs"] = {}
        with self.assertRaises(KeyError):
            check(needs)


if __name__ == "__main__":
    unittest.main()
