# App User Scope And Metadata Recovery

1. Bind User, System, and Active app snapshots to a numeric Android user.
   Require that same user for app actions and helper metadata requests; reject
   a changed active user before issuing a mutation. Uninstall must never use
   Android's default all-user scope.
2. Keep Android 8/10 compatibility. Launch through user-scoped Android activity
   commands with Leanback and standard launcher fallback. Keep helper replacement
   scoped to the active user as well.
3. Separate a missing metadata helper from temporary page failures. Continue
   later pages after a temporary failure, retain completed pages, and allow the
   failed packages to be retried. Cancellation and a changed user stop loading.
4. Extract the metadata loading loop into a small testable app operation. Avoid
   unrelated root-view restructuring and new production dependencies.
5. Cover numeric command scope, changed-user rejection, missing packages/helper,
   page recovery, retry, and cancellation. Run portable tests locally, then the
   required macOS SwiftPM and iOS build checks through a PR.

Physical acceptance remains necessary for Android 8/10 multi-user behavior,
network interruption, and the recent upload/large-library stability changes.
No real TV or iOS device is attached to this environment.

## Implementation And Local Validation

- Implemented numeric-user snapshots and action/metadata commands, including
  user rechecks before mutations and rejection of stale list snapshots.
- Activity launch resolves Leanback first, falls back to the standard launcher
  only when no Leanback activity exists, and requires a successful Android
  `Status: ok` result. No uncertain launch is replayed.
- The metadata operation publishes completed pages, continues after temporary
  page failures, stops for a missing helper or changed user, and retries only
  failed packages. Late cancelled pages cannot publish results.
- A temporary Swift 6.2.4/Linux package passed 330 tests using unchanged core,
  app model, state, metadata-operation, and file-operation sources. The install
  event declarations were copied verbatim from the existing install operation
  to satisfy the portable model target without importing Apple-only UI code.
  Apple-specific sources and tests remain covered by the full macOS CI suite.
- All app sources and app tests passed `swiftc -frontend -parse`;
  `git diff --check` also passed.
- Physical scenarios have been added to `hardware-test-checklist.md`; they
  have not been executed for this change.

## Android Compatibility References

- [Android 8 package-manager user defaults and activity resolution](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-8.0.0_r1/services/core/java/com/android/server/pm/PackageManagerShellCommand.java)
- [Android 8 user-scoped content reads](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-8.0.0_r1/cmds/content/src/com/android/commands/content/Content.java)
- [Android 8 activity launch result and exit status](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-8.0.0_r1/services/core/java/com/android/server/am/ActivityManagerShellCommand.java)
