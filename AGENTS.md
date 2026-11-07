# Agent instructions

Read `.github/copilot-instructions.md` first; it is the source of truth for this repository.

## Non-negotiable: every change is tested
- Every code change (feature, bug fix, crash fix, refactor, UI change) must add or update unit tests in `NanoKVM/NanoKVMTests` in the same change.
- Bug and crash fixes need a regression test reproducing the failing input.
- The full test suite must pass on macOS, and the iOS target must at least build for testing, before the work is reported as done:
  ```
  xcodebuild test -project NanoKVM/NanoKVM.xcodeproj -scheme NanoKVM -destination 'platform=macOS' -enableCodeCoverage YES -resultBundlePath /tmp/r.xcresult
  xcodebuild build-for-testing -project NanoKVM/NanoKVM.xcodeproj -scheme NanoKVM -destination 'generic/platform=iOS Simulator'
  ```
- Do not delete or weaken tests to get a green build. Do not let coverage drop; logic files stay above 90%.
