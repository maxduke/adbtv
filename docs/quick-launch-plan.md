# Quick Launch and remaining accessibility polish

Add a small, local Quick Launch surface to Remote, reusing the checked app
launcher. Keep iOS App Intents and system shortcuts for a later feature.

## Scope

- Pin/unpin apps from User, System, or Active Apps. Limit each TV/Android user
  to six unique packages; support removal and reordering from Remote.
- Store package identifiers, optional bounded display names, and order locally.
  Key preferences by the saved device UUID and numeric Android user. Rename and
  connection repair retain preferences; deleting a device removes its entries.
- Resolve the current TV user before showing that user's pins, without loading
  the entire Apps list. Never execute a pin using another user's snapshot.
- Reuse checked launch, installed-package verification, launcher resolution,
  user-change detection, operation ownership, cancellation, and timeout paths.
  No automatic replay, new production dependency, or required helper change.
- Keep Quick Launch compact with a horizontal row and a separate management
  sheet. Show it above the remote at standard text sizes and after the main
  controls at accessibility sizes, preserving first-screen access to the D-pad.
- Finish the previously observed large-text issues in Files, App Details, and
  Rename, and use app names plus package identifiers in uninstall confirmation.

## Validation

Test scoped persistence, duplicate/max limits, ordering, corrupt-data protection,
device deletion, and user identity validation. Run portable core/model tests
and parse UI sources locally, then require full SwiftPM/iOS CI and focused
iPhone/iPad snapshots in both appearances and text sizes. Exercise quick-launch
success/failure/empty/management previews. Real TV, VoiceOver, external keyboard,
and interactive reorder/hold behavior remain physical/manual acceptance.

The focused `quick-launch` snapshot scope covers ten screens across eight
device/appearance/text-size combinations (80 images). Chip labels use at most
two lines to keep Remote compact; Manage and VoiceOver expose full app names.

Local checks: 353 portable tests pass (including scoped preferences, stale
window edits, current-user lookup, and dropping queued remote keys). All app/UI
and app-test Swift sources parse under Swift 6.2.4. Snapshot workflow YAML and
shell syntax pass; dry runs verify 8 library, 80 focused, and 180 full captures
with unique output filenames. Apple SDK type checking and snapshot acceptance
are part of PR delivery.
