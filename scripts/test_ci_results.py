"""Allow only planned job skips without weakening required checks."""

import copy
import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import check_ci_results


def needs_data(engine, dependencies, app=False, tooling=False):
    needs = {name: {"result": "success"} for name in check_ci_results.REQUIRED}
    plan = {
        "engine_required": str(engine).lower(),
        "dependencies_required": str(dependencies).lower(),
        "app_required": str(app).lower(),
        "tooling_required": str(tooling).lower(),
    }
    needs["changes"]["outputs"] = plan
    needs.update(
        {
            name: {"result": "success" if plan[flag] == "true" else "skipped"}
            for name, flag in check_ci_results.CONDITIONAL.items()
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
    def test_docs_tooling_app_dependency_and_engine_plans_pass(self):
        for args in (
            (False, False),
            (False, False, False, True),
            (False, False, True, True),
            (False, True),
            (True, True),
        ):
            check(needs_data(*args))

    def test_failure_cancellation_and_unplanned_skips_never_pass(self):
        for engine, dependencies in ((True, True), (False, True), (False, False)):
            expected = needs_data(engine, dependencies)
            for job in expected:
                for status in ("success", "failure", "cancelled", "skipped", "neutral"):
                    if status == expected[job]["result"]:
                        continue
                    with (
                        self.subTest(job=job, status=status),
                        self.assertRaises(SystemExit),
                    ):
                        needs = copy.deepcopy(expected)
                        needs[job]["result"] = status
                        check(needs)

    def test_missing_unexpected_and_invalid_plan_data_fail(self):
        for name in needs_data(False, False):
            needs = needs_data(False, False)
            del needs[name]
            with self.subTest(missing=name), self.assertRaises(SystemExit):
                check(needs)
        needs = needs_data(False, False)
        needs["extra"] = {"result": "success"}
        with self.assertRaises(SystemExit):
            check(needs)
        for flag in check_ci_results.OUTPUTS:
            for value in ("", "False", None, False):
                needs = needs_data(False, False)
                needs["changes"]["outputs"][flag] = value
                with (
                    self.subTest(flag=flag, value=value),
                    self.assertRaises(SystemExit),
                ):
                    check(needs)
        needs = needs_data(False, False)
        needs["changes"]["outputs"] = {}
        with self.assertRaises(SystemExit):
            check(needs)

    def test_engine_plan_cannot_skip_dependency_checks(self):
        with self.assertRaises(SystemExit):
            check(needs_data(True, False))


if __name__ == "__main__":
    unittest.main()
