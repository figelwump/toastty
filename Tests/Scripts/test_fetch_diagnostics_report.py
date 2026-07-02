#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import os
import sys
import unittest
from unittest import mock
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

    def test_admin_list_url_accepts_base_and_endpoint_urls(self) -> None:
        self.assertEqual(
            fetch_diagnostics_report.admin_list_url("https://diagnostics.example.com", 25),
            "https://diagnostics.example.com/v1/diagnostics?limit=25",
        )
        self.assertEqual(
            fetch_diagnostics_report.admin_list_url("https://diagnostics.example.com/v1/diagnostics", 5),
            "https://diagnostics.example.com/v1/diagnostics?limit=5",
        )

        with self.assert_fails_with("limit must be a positive integer"):
            fetch_diagnostics_report.admin_list_url("https://diagnostics.example.com", 0)

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

    def test_describe_automation_call_uses_event_type_when_command_is_absent(self) -> None:
        rendered = fetch_diagnostics_report.describe_automation_call({
            "timestampMs": 1_800_000_000_000,
            "kind": "event",
            "eventType": "session.status",
            "callerAgent": "mimocode",
            "ok": True,
            "durationMs": 0,
        })

        self.assertIn("event | session.status", rendered)
        self.assertNotIn("event | ?", rendered)

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

    def test_print_report_list_shows_submission_time_and_note_preview(self) -> None:
        listing = {
            "generatedAtMs": 1_800_000_000_000,
            "limit": 25,
            "reports": [
                {
                    "reportID": "TT-20260701-ABCDEFGHJKLMNPQR",
                    "receivedAtMs": 1_800_000_000_000,
                    "expiresAtMs": 1_800_086_400_000,
                    "summary": {
                        "appVersion": "0.1.0",
                        "build": "1",
                        "runtimeLabel": "toastty-test",
                        "socketState": "healthy",
                        "notePreview": "contact: user@example.com",
                    },
                }
            ],
        }

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            fetch_diagnostics_report.print_report_list(listing)

        rendered = stdout.getvalue()
        self.assertIn("Toastty diagnostics submissions", rendered)
        self.assertIn("TT-20260701-ABCDEFGHJKLMNPQR", rendered)
        self.assertIn("submitted 2027-01-15T08:00:00+00:00", rendered)
        self.assertIn("note/contact: contact: user@example.com", rendered)

    def test_print_report_list_handles_empty_and_missing_summary(self) -> None:
        listing = {
            "generatedAtMs": 1_800_000_000_000,
            "limit": 25,
            "reports": [],
        }

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            fetch_diagnostics_report.print_report_list(listing)
        self.assertIn("None found", stdout.getvalue())

        missing_summary = {
            "generatedAtMs": 1_800_000_000_000,
            "limit": 25,
            "reports": [{"reportID": "TT-20260701-ABCDEFGHJKLMNPQR"}],
        }
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            fetch_diagnostics_report.print_report_list(missing_summary)
        rendered = stdout.getvalue()
        self.assertIn("TT-20260701-ABCDEFGHJKLMNPQR", rendered)
        self.assertIn("app ? (?)", rendered)

    def test_print_report_list_ignores_extra_sensitive_fields(self) -> None:
        listing = {
            "generatedAtMs": 1_800_000_000_000,
            "limit": 25,
            "reports": [
                {
                    "reportID": "TT-20260701-ABCDEFGHJKLMNPQR",
                    "rawBundle": "DO_NOT_PRINT_BUNDLE",
                    "env": "DO_NOT_PRINT_ENV",
                    "logs": "DO_NOT_PRINT_LOGS",
                    "summary": {
                        "appVersion": "0.1.0",
                        "build": "1",
                        "runtimeLabel": "toastty-test",
                        "socketState": "healthy",
                        "secretScanFindings": ["DO_NOT_PRINT_SECRET_SCAN"],
                        "notePreview": "contact: user@example.com",
                    },
                }
            ],
        }

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            fetch_diagnostics_report.print_report_list(listing)
        rendered = stdout.getvalue()
        self.assertNotIn("DO_NOT_PRINT_BUNDLE", rendered)
        self.assertNotIn("DO_NOT_PRINT_ENV", rendered)
        self.assertNotIn("DO_NOT_PRINT_LOGS", rendered)
        self.assertNotIn("DO_NOT_PRINT_SECRET_SCAN", rendered)

    def test_main_without_report_id_lists_recent_submissions(self) -> None:
        captured = {}

        def fake_fetch(url: str, admin_key: str, timeout: float) -> str:
            captured["url"] = url
            captured["admin_key"] = admin_key
            captured["timeout"] = timeout
            return '{"generatedAtMs":1800000000000,"limit":2,"reports":[]}'

        stdout = io.StringIO()
        with mock.patch.dict(os.environ, {"TOASTTY_DIAGNOSTICS_ADMIN_KEY": "admin-key"}, clear=False):
            with mock.patch.object(sys, "argv", [
                "fetch-diagnostics-report.py",
                "--endpoint",
                "https://diagnostics.example.com",
                "--limit",
                "2",
            ]):
                with mock.patch.object(fetch_diagnostics_report, "fetch_report", side_effect=fake_fetch):
                    with contextlib.redirect_stdout(stdout):
                        self.assertEqual(fetch_diagnostics_report.main(), 0)

        self.assertEqual(captured["url"], "https://diagnostics.example.com/v1/diagnostics?limit=2")
        self.assertEqual(captured["admin_key"], "admin-key")
        self.assertIn("None found", stdout.getvalue())

    def test_main_rejects_malformed_report_id_before_admin_key_lookup(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch.object(sys, "argv", ["fetch-diagnostics-report.py", "not-a-report"]):
                with self.assert_fails_with("expected a report ID"):
                    fetch_diagnostics_report.main()

    @contextlib.contextmanager
    def assert_fails_with(self, expected: str):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit):
                yield
        self.assertIn(expected, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
