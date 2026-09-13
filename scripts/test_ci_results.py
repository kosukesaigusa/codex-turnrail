"""Keep failed, cancelled, and skipped work from satisfying the release gate."""

import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import check_ci_results


class CiResultsTests(unittest.TestCase):
    def test_every_dependency_must_succeed(self):
        with (
            patch.dict(
                check_ci_results.os.environ,
                {
                    "NEEDS": json.dumps(
                        {"app": {"result": "success"}, "engine": {"result": "success"}}
                    )
                },
            ),
            redirect_stdout(io.StringIO()),
        ):
            check_ci_results.main()

    def test_unsuccessful_or_missing_work_cannot_pass(self):
        for status in ("failure", "cancelled", "skipped", "neutral"):
            with (
                self.subTest(status=status),
                patch.dict(
                    check_ci_results.os.environ,
                    {
                        "NEEDS": json.dumps(
                            {"app": {"result": "success"}, "engine": {"result": status}}
                        )
                    },
                ),
                redirect_stdout(io.StringIO()),
                self.assertRaises(SystemExit),
            ):
                check_ci_results.main()
        with (
            patch.dict(check_ci_results.os.environ, {"NEEDS": "{}"}),
            self.assertRaises(SystemExit),
        ):
            check_ci_results.main()


if __name__ == "__main__":
    unittest.main()
