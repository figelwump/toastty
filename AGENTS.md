# Repo Workflow Notes

## Live-App Validation Expectations
- For any UI/runtime change, validate in the running `ToasttyApp`, not only reducer/unit tests.
- Prefer validating both:
  - automation path (`./scripts/automation/smoke-ui.sh`)
  - manual/live interaction path (launch app, drive UI, inspect screenshot output)

## Ghostty-Specific Validation
- When validating Ghostty-backed terminal behavior, regenerate with Ghostty enabled:
  - `TUIST_ENABLE_GHOSTTY=1 tuist generate`
- Build/run with a deterministic derived-data path:
  - `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`

## Automation + Screenshot Workflow
- Primary smoke run:
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
- Full build/test gate:
  - `./scripts/automation/check.sh`
- Store manual validation captures under:
  - `artifacts/manual/`
- `artifacts/` is already gitignored in this repo; keep captures there and do not commit them.
- For scripted keyboard interaction (System Events), click into the target terminal panel before typing; activation alone is not always enough.
- Example focus/typing sequence:
  - `osascript -e 'tell application "ToasttyApp" to activate' -e 'tell application "System Events" to click at {720, 360}' -e 'tell application "System Events" to keystroke "ls -l"' -e 'tell application "System Events" to key code 36'`
- After scripted interaction, always inspect the screenshot artifact to confirm expected behavior (focus, prompt position, scrolling, panel layout).
