# Saved iPhone diagnostics

The native iPhone app saves a small diagnostics report in its app data container.
The report contains the app version and build, a run ID, timestamps, up to 128
categorical events, and an optional push state snapshot. It does not contain raw
errors, terminal contents, credentials, device tokens, or connection addresses.
The recorder's typed fields enforce this privacy boundary. The collector
preserves additive fields; it does not act as a general report redaction tool.

The app saves the current run at
`Library/Application Support/ToasttyDiagnostics/current.json`. On the first
successful save of a new run, it retains the prior report as `previous.json`.
There is at most one retained prior report. These files are saved captures. They
do not prove that the app is running or that a network request currently works.
An app that is suspended or terminated cannot update the report. An abrupt
termination can leave the last saved state before the failure.

## Collect a report

The app build with the recorder must be installed and must have run before a
report exists. The Mac needs Xcode with `devicectl`, a paired physical iPhone,
and access to the selected app's data container. Container access depends on the
installed app and device permissions. A successful development-build copy does
not establish access to a TestFlight or App Store app.

Run this from the repository root. Use the exact device identifier and installed
app bundle ID. The command reads one file from that iPhone and writes a local
JSON artifact. It does not install, launch, terminate, or change the device app.

```bash
node ios/scripts/collect-diagnostics.mjs \
  --device '<device-identifier>' \
  --bundle-id com.giantthings.toastty.mobile.dev \
  --output artifacts/manual/iphone-diagnostics.json
```

Add `--dry-run` to show the command without contacting a device or writing a
report. Add `--previous` to copy the retained prior run instead of the current
run. The collector never falls back between those files. A missing file fails.

The collector copies into a new private temporary directory. It accepts only a
regular JSON file up to 256 KiB with schema version 1 and valid run, app, event,
and timestamp fields. It checks that the report bundle ID matches `--bundle-id`.
Additive fields are permitted. After validation, it replaces `--output`
atomically with permissions `0600`, so only the current user can read or write
the saved report. It writes the parsed JSON document, so duplicate keys cannot
retain values that differ from the validated identity. Temporary copies are
removed. Keep output under gitignored
`artifacts/`; do not commit device captures.

The collector prints the snapshot timestamp and age. If push state is present,
it prints a short summary of the stage, permission, reconciliation state, active
registration state, last action, last return reason and time, cooldown deadlines,
and scheduled retry. Only bounded category names, booleans, and parsed timestamps
can appear in this summary. Missing or malformed optional fields are omitted.
Cooldown seconds remaining are derived from each deadline and the report's
`capturedAt` timestamp. They describe a frozen observation at capture, not the
current live state. The snapshot stores `reconciling`,
`activeRegistrationEnabled`, and `permission`; it does not store a countdown that
could become stale while the app is suspended.

By default, the collector accepts old
reports so that diagnostics remain available after suspension or a crash. Use
`--expected-build '<build-number>'` to require an exact app build. Use
`--max-age-seconds 300` to reject snapshots more than five minutes old. The age
limit accepts finite values from zero through 31536000 seconds. Regardless of
the age limit, timestamps more than 60 seconds in the future fail; check the Mac
and iPhone clocks. The report's run start cannot follow its capture timestamp.
Within the allowed clock skew, a future capture has a displayed age of zero and
an explicit message that the device clock is ahead.

If copy or validation fails, the command exits with status 1 and does not replace
the destination. If an error occurs after the validated file was saved, the
error message says that the file was saved. A prior local output file can still
exist after failure. Check
the exit status and the printed snapshot age before using a capture as evidence.
The collector does not print raw device command output or arbitrary report
strings. Copy errors report a timeout, exit status, or signal when available.

## Validate the collector

```bash
node --test ios/Tests/ScriptTests/collect-diagnostics.test.mjs
```

This local test uses a fake `xcrun` executable. It checks the exact read-only
copy arguments, identity and time validation, output permissions, prior-run
selection, and failure without reuse of earlier output. It does not contact a
physical device or establish production container access. Physical-device
validation must record the installed build, bundle ID, selected device, command
exit status, saved artifact path, and printed snapshot time and age.
