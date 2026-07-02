#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, NoReturn

DEFAULT_ENDPOINT = "https://toastty-diagnostics.giantthings.workers.dev"
REPORT_ID_RE = re.compile(r"^TT-[0-9]{8}-[A-Z2-9]{16}$")
LOG_MATCH_RE = re.compile(r"\b(error|warn|warning|failed|failure|exception|fatal)\b", re.IGNORECASE)
DEFAULT_AUTOMATION_DISPLAY_LIMIT = 20


def main() -> int:
    parser = argparse.ArgumentParser(
        description="List, fetch, and summarize Toastty diagnostics reports."
    )
    parser.add_argument("report_id", nargs="?", help="Toastty report ID, e.g. TT-20260701-ABCDEFGHJKLMNPQR")
    parser.add_argument("--file", dest="input_file", help="Summarize an already-downloaded report envelope JSON file")
    parser.add_argument("--endpoint", help="Diagnostics Worker base URL or /v1/diagnostics endpoint URL")
    parser.add_argument("--output", help="Output path for fetched report JSON; defaults to artifacts/diagnostics/<reportID>.json")
    parser.add_argument("--limit", type=int, default=25, help="Maximum recent submissions to list when report_id is omitted")
    parser.add_argument("--timeout", type=float, default=30.0, help="Fetch timeout in seconds")
    parser.add_argument("--log-matches", type=int, default=20, help="Maximum warning/error-like log lines to print")
    parser.add_argument(
        "--automation-calls",
        type=int,
        default=DEFAULT_AUTOMATION_DISPLAY_LIMIT,
        help="Maximum recent automation calls to print"
    )
    args = parser.parse_args()

    if args.input_file:
        envelope = load_json_file(Path(args.input_file))
        print_summary(
            envelope,
            source=f"local file {args.input_file}",
            log_match_limit=args.log_matches,
            automation_limit=args.automation_calls
        )
        return 0

    report_id = (args.report_id or "").strip()
    if report_id and not REPORT_ID_RE.match(report_id):
        fail("expected a report ID like TT-20260701-ABCDEFGHJKLMNPQR")

    admin_key = os.environ.get("TOASTTY_DIAGNOSTICS_ADMIN_KEY", "")
    if not admin_key:
        fail("TOASTTY_DIAGNOSTICS_ADMIN_KEY is missing; run through `sv exec --`")

    endpoint = args.endpoint or os.environ.get("TOASTTY_DIAGNOSTICS_ENDPOINT") or DEFAULT_ENDPOINT
    if not report_id:
        url = admin_list_url(endpoint, args.limit)
        raw = fetch_report(url, admin_key, timeout=args.timeout)
        listing = parse_report_json(raw, source=url)
        print_report_list(listing)
        return 0

    url = admin_report_url(endpoint, report_id)
    raw = fetch_report(url, admin_key, timeout=args.timeout)
    envelope = parse_report_json(raw, source=url)

    output_path = Path(args.output) if args.output else Path("artifacts") / "diagnostics" / f"{report_id}.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(raw, encoding="utf-8")

    print(f"Saved report: {output_path}")
    print_summary(envelope, source=url, log_match_limit=args.log_matches, automation_limit=args.automation_calls)
    return 0


def diagnostics_endpoint_url(endpoint: str) -> str:
    endpoint = endpoint.strip()
    if not endpoint:
        fail("endpoint is empty")
    parsed = urllib.parse.urlsplit(endpoint)
    if not parsed.scheme or not parsed.netloc:
        fail(f"endpoint must be an absolute URL: {endpoint}")
    path = parsed.path.rstrip("/")
    if not path.endswith("/v1/diagnostics"):
        path = f"{path}/v1/diagnostics"
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def admin_list_url(endpoint: str, limit: int) -> str:
    if limit < 1:
        fail("limit must be a positive integer")
    query = urllib.parse.urlencode({"limit": str(limit)})
    return f"{diagnostics_endpoint_url(endpoint)}?{query}"


def admin_report_url(endpoint: str, report_id: str) -> str:
    encoded_report_id = urllib.parse.quote(report_id, safe="")
    return f"{diagnostics_endpoint_url(endpoint)}/{encoded_report_id}"


def fetch_report(url: str, admin_key: str, timeout: float) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "accept": "application/json",
            "x-toastty-admin-key": admin_key,
            "user-agent": "toastty-diagnostics-skill/1"
        }
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        fail(f"fetch failed with HTTP {error.code}: {body[:500]}")
    except urllib.error.URLError as error:
        fail(f"fetch failed: {error.reason}")


def load_json_file(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"could not read {path}: {error}")
    return parse_report_json(raw, source=str(path))


def parse_report_json(raw: str, source: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        fail(f"{source} is not valid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{source} must contain a JSON object")
    return value


def print_summary(envelope: dict[str, Any], source: str, log_match_limit: int, automation_limit: int) -> None:
    report_id = text(envelope.get("reportID")) or "(missing)"
    summary = record(envelope.get("summary"))
    bundle = record(envelope.get("bundle"))
    logs = record(bundle.get("logs"))
    current_log = record(logs.get("current"))
    previous_log = record(logs.get("previous"))
    automation = record(bundle.get("automation"))
    recent_requests = list_value(automation.get("recentRequests"))
    socket = record(bundle.get("socket"))
    redaction = record(bundle.get("redaction"))
    secret_scan_count = summary.get("secretScanFindingCount")
    if not isinstance(secret_scan_count, int):
        secret_scan_count = len(list_value(summary.get("secretScanFindings")))

    print("")
    print("Toastty diagnostics")
    print(f"- Report ID: {report_id}")
    print(f"- Source: {source}")
    print(f"- Received: {format_ms(envelope.get('receivedAtMs'))}")
    print(f"- Expires: {format_ms(envelope.get('expiresAtMs'))}")
    print(f"- App: {text(summary.get('appVersion')) or '?'} ({text(summary.get('build')) or '?'})")
    print(f"- Runtime: {text(summary.get('runtimeLabel')) or '?'}")
    print(f"- Socket: {text(summary.get('socketState')) or text(socket.get('state')) or '?'}")
    print(
        "- Redaction: "
        f"rules v{first_present(redaction.get('rulesVersion'), summary.get('redactionRulesVersion'), '?')}, "
        f"{first_present(redaction.get('redactedKeyCount'), summary.get('redactedKeyCount'), '?')} redacted keys"
    )
    print(f"- Secret scan: override={str(summary.get('secretScanOverride')).lower()}, findings={secret_scan_count}")
    print(
        "- Logs: "
        f"current {format_bytes(current_log.get('sizeBytes'))}"
        f"{' truncated' if current_log.get('truncated') else ''}; "
        f"previous {format_bytes(previous_log.get('sizeBytes'))}"
        f"{' truncated' if previous_log.get('truncated') else ''}"
    )
    print(f"- Automation audit: {len(recent_requests)} recent calls recorded")

    note = text(bundle.get("note")) or text(summary.get("notePreview"))
    if note:
        print(f"- Note: {collapse(note, 220)}")

    print("")
    print("Recent automation calls")
    if recent_requests:
        displayed_requests = recent_requests[-max(automation_limit, 0):] if automation_limit > 0 else []
        if len(displayed_requests) < len(recent_requests):
            print(f"- Showing last {len(displayed_requests)} of {len(recent_requests)} recorded calls")
        for item in displayed_requests:
            print(f"- {describe_automation_call(record(item))}")
    else:
        print("- None recorded")

    log_matches = matching_log_lines(text(current_log.get("content")) or "", log_match_limit)
    print("")
    print("Warning/error-like log lines")
    for line in log_matches:
        print(f"- {line}")
    if not log_matches:
        print("- None matched in current log content")


def print_report_list(listing: dict[str, Any]) -> None:
    reports = list_value(listing.get("reports"))
    limit = listing.get("limit")
    print("")
    print("Toastty diagnostics submissions")
    print(f"- Generated: {format_ms(listing.get('generatedAtMs'))}")
    print(f"- Count: {len(reports)} shown" + (f" (limit {limit})" if isinstance(limit, int) else ""))

    if not reports:
        print("")
        print("Recent submissions")
        print("- None found")
        return

    print("")
    print("Recent submissions")
    for value in reports:
        report = record(value)
        summary = record(report.get("summary"))
        report_id = text(report.get("reportID")) or "?"
        app_version = text(summary.get("appVersion")) or "?"
        build = text(summary.get("build")) or "?"
        runtime = text(summary.get("runtimeLabel")) or "?"
        socket = text(summary.get("socketState")) or "?"
        note_preview = text(summary.get("notePreview"))
        print(
            f"- {report_id} | submitted {format_ms(report.get('receivedAtMs'))} "
            f"| expires {format_ms(report.get('expiresAtMs'))} "
            f"| app {app_version} ({build}) | runtime {runtime} | socket {socket}"
        )
        if note_preview:
            print(f"  note/contact: {collapse(note_preview, 180)}")


def describe_automation_call(item: dict[str, Any]) -> str:
    parts = [
        format_ms(item.get("timestampMs")),
        text(item.get("kind")) or "?",
        text(item.get("command")) or "?",
    ]
    action_id = text(item.get("actionID"))
    if action_id:
        parts.append(f"action={action_id}")
    caller = text(item.get("callerAgent")) or text(item.get("callerSessionID"))
    if caller:
        parts.append(f"caller={caller}")
    selectors = record(item.get("selectors"))
    if selectors:
        parts.append("selectors=" + ",".join(sorted(selectors.keys())))
    flags = record(item.get("flags"))
    if flags:
        rendered_flags = [f"{key}={json.dumps(flags[key], separators=(',', ':'))}" for key in sorted(flags.keys())]
        parts.append("flags=" + ",".join(rendered_flags))
    if "ok" in item:
        parts.append("ok=" + str(item.get("ok")).lower())
    if "durationMs" in item:
        parts.append(f"{item.get('durationMs')}ms")
    return " | ".join(parts)


def matching_log_lines(content: str, limit: int) -> list[str]:
    if limit <= 0 or not content:
        return []
    matches: list[str] = []
    for line in content.splitlines():
        if LOG_MATCH_RE.search(line):
            matches.append(collapse(line, 260))
    return matches[-limit:]


def record(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def list_value(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def text(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def first_present(*values: Any) -> Any:
    for value in values:
        if value is not None:
            return value
    return None


def collapse(value: str, limit: int) -> str:
    collapsed = " ".join(value.split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 3] + "..."


def format_ms(value: Any) -> str:
    if not isinstance(value, (int, float)):
        return "?"
    return dt.datetime.fromtimestamp(value / 1000, tz=dt.timezone.utc).isoformat()


def format_bytes(value: Any) -> str:
    if not isinstance(value, (int, float)):
        return "?"
    units = ["B", "KB", "MB", "GB"]
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(amount)} {unit}"
            return f"{amount:.1f} {unit}"
        amount /= 1024
    return f"{amount:.1f} GB"


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    raise SystemExit(main())
