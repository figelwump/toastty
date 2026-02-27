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
  - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build`

## Automation + Screenshot Workflow
- Primary smoke run:
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
- Full build/test gate:
  - `./scripts/automation/check.sh`
- Store manual validation captures under:
  - `artifacts/manual/`
- For scripted keyboard interaction (System Events), click into the target terminal panel before typing; activation alone is not always enough.
- After scripted interaction, always inspect the screenshot artifact to confirm expected behavior (focus, prompt position, scrolling, panel layout).
