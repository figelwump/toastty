#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py"

spec = importlib.util.spec_from_file_location("fetch_diagnostics_report", SCRIPT)
if spec is None or spec.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
fetch_diagnostics_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch_diagnostics_report)


class FetchDiagnosticsReportTests(unittest.TestCase):
    def test_admin_report_url_accepts_base_and_endpoint_urls(self) -> None:
        report_id = "TT-20260701-ABCDEFGHJKLMNPQR"

        self.assertEqual(
            fetch_diagnostics_report.admin_report_url("https://diagnostics.example.com", report_id),
            "https://diagnostics.example.com/v1/diagnostics/TT-20260701-ABCDEFGHJKLMNPQR",
        )
        self.assertEqual(
            fetch_diagnostics_report.admin_report_url("https://diagnostics.example.com/v1/diagnostics", report_id),
            "https://diagnostics.example.com/v1/diagnostics/TT-20260701-ABCDEFGHJKLMNPQR",
        )
        self.assertEqual(
            fetch_diagnostics_report.admin_report_url("https://diagnostics.example.com/support?ignored=1#frag", report_id),
            "https://diagnostics.example.com/support/v1/diagnostics/TT-20260701-ABCDEFGHJKLMNPQR",
        )

    def test_parse_report_json_requires_json_object(self) -> None:
        self.assertEqual(fetch_diagnostics_report.parse_report_json('{"reportID":"TT"}', "source"), {"reportID": "TT"})

        with self.assert_fails_with("not valid JSON"):
            fetch_diagnostics_report.parse_report_json("{", "source")

        with self.assert_fails_with("must contain a JSON object"):
            fetch_diagnostics_report.parse_report_json("[]", "source")

    def test_matching_log_lines_returns_tail(self) -> None:
        content = "\n".join([
            "info first",
            "warning one",
            "error two",
            "failed three",
        ])

        self.assertEqual(
            fetch_diagnostics_report.matching_log_lines(content, 2),
            ["error two", "failed three"],
        )

    def test_describe_automation_call_includes_focus_flag(self) -> None:
        rendered = fetch_diagnostics_report.describe_automation_call({
            "timestampMs": 1_800_000_000_000,
            "kind": "request",
            "command": "app_control.run_action",
            "actionID": "workspace.select",
            "callerAgent": "codex",
            "selectors": {"workspaceID": "workspace-1"},
            "flags": {"focusUnreadSessionPanel": True},
            "ok": True,
            "durationMs": 4,
        })

        self.assertIn("action=workspace.select", rendered)
        self.assertIn("selectors=workspaceID", rendered)
        self.assertIn("flags=focusUnreadSessionPanel=true", rendered)

    def test_print_summary_distinguishes_recorded_and_displayed_automation_calls(self) -> None:
        envelope = {
            "reportID": "TT-20260701-ABCDEFGHJKLMNPQR",
            "summary": {
                "redactionRulesVersion": 1,
                "redactedKeyCount": 0,
                "secretScanOverride": False,
                "secretScanFindings": [],
            },
            "bundle": {
                "logs": {"current": {"content": ""}, "previous": {}},
                "automation": {
                    "recentRequests": [
                        {"timestampMs": 1_800_000_000_000 + index, "kind": "request", "command": f"command.{index}"}
                        for index in range(3)
                    ]
                },
                "redaction": {"rulesVersion": 1, "redactedKeyCount": 0},
            },
        }

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            fetch_diagnostics_report.print_summary(
                envelope,
                source="test",
                log_match_limit=20,
                automation_limit=2,
            )

        rendered = stdout.getvalue()
        self.assertIn("Automation audit: 3 recent calls recorded", rendered)
        self.assertIn("Showing last 2 of 3 recorded calls", rendered)

    @contextlib.contextmanager
    def assert_fails_with(self, expected: str):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit):
                yield
        self.assertIn(expected, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
