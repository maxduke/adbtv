# Stability Review Implementation

Scope: address the review of `ade66bb` without new production dependencies or
changes to the app's navigation.

1. Isolate checked shell commands so explicit exit, trailing comments, and
   background command syntax cannot consume the status marker.
2. Recheck upload destinations on the TV, require explicit replacement, and
   validate the final move. Preserve staging cleanup failures and use an
   independent, bounded connection after cancellation or disconnect.
3. Bound folder reads, mutations, transfers, and stalled transfers. Track file
   operation ownership through cancellation and reject late view updates.
4. Load installed-app details in bounded pages, publish completed pages, and
   allow later packages to load instead of silently stopping at 128.
5. Extract installed-app views and state from the root view. Include the helper
   verification script in Android CI path filters.
6. Add regression tests for actual shell execution, upload conflicts and
   cleanup, timeouts/cancellation, and metadata beyond the first page. Update
   README and physical-device checks.

Validation uses the existing Swift package where the host supports it, plus
portable Swift tests in Docker for platform-independent changes. A Linux host
cannot establish Xcode/SwiftUI build or physical Android TV acceptance.

Android 8 compatibility matters: its Toybox `mv` supports `-n` but not `-T`.
Destination checks and move postconditions must not introduce newer-only flags.
These shell checks do not provide transactional isolation from other TV apps
that concurrently change the same destination.

Reference: [Android 8 Toybox copy/move implementation](https://android.googlesource.com/platform/external/toybox/+/android-8.0.0_r1/toys/posix/cp.c).

## Implementation And Validation

- All six implementation steps above are complete. Upload replacement is an
  explicit opt-in, and cleanup failures retain their exact staging path.
- Folder reads and mutations have a 30-second limit. Transfers have a
  15-minute total limit and a 30-second inactivity limit; interruption cleanup
  uses its own connection and 45-second limit.
- Installed-app views and state were extracted into their own source files;
  their bodies were compared with the original version to confirm the move.
- A temporary Swift package using unchanged repository core sources, the
  existing BoringSSL dependency, and the file-operation/timeout sources passed
  266 tests on Swift 6.2.4/Linux. This includes all platform-independent core
  tests and the file-operation/timeout tests; it excludes Apple-only tests and
  the remaining SwiftUI app tests.
- `swiftc -frontend -parse` passed for every app source and app test file.
  `git diff --check`, shell script syntax, plist/XML parsing, and helper CI path
  assertions also passed.
- The full repository `swift test` was also attempted against an isolated
  snapshot. On Linux it stops at the existing `CoreTransferable` import in
  `ADBTVDeviceToolsView.swift`; Apple frameworks are unavailable on that host.
- Full macOS Swift package tests, the iOS simulator build, screenshots, and
  physical Android 8/10 checks remain required before release. The physical
  scenarios are recorded in `hardware-test-checklist.md`.
