# Sequential multi-file uploads

## Scope

- Select up to 100 local files in Tools → Files and upload them, in picker order,
  to the captured TV and directory. Keep APK installation single-selection.
- Present a scrollable upload sheet with the destination, overall file count,
  per-file byte progress, and explicit uploaded/skipped/unfinished outcomes.
  Put progress, current-file decisions, and failures before connection details.
  Use page-sized presentation on iOS 18+ so iPad accessibility layouts have room;
  keep the existing presentation on iOS 17.
- Refresh the TV directory before each upload. Pause on a name conflict; allow
  Replace for regular files only, Skip, or Cancel Uploads. A folder, link, or
  other non-regular item can only be skipped. Decisions apply to one file.
- Reuse existing staged writes, commit-time conflict/type checks, per-file
  transfer limits, and independent bounded cleanup. No automatic retry or replay.
- Stop on the first transfer, listing, or cleanup failure. Cancellation prevents
  later uploads and retains ownership until the current transfer and cleanup end.
  Preserve completed files and show the remaining results without rollback.
- Keep the queue in memory, bind it to the originating TV/path, cancel on leaving
  its owner or backgrounding, and refresh Files after closing the results. Do not promise background
  transfer or resumability. Add no production dependency.
- Keep English/Chinese text and accessibility layouts consistent. Configuration
  backup, shortcuts, batch delete/download, and unrelated UI tests are separate.

## Implementation and validation

1. Add a small observable queue model with injectable directory/upload operations.
   Test sequential ordering, conflicts (including duplicate destination names),
   skip/replace decisions, cancellation before/during work and while paused,
   cleanup failures, stale progress, and truthful partial results.
2. Add multi-selection to the shared picker, preserving single-APK behavior, and
   connect the model to a scrollable upload sheet using the existing file helpers.
3. Add English/Chinese strings, deterministic active/conflict/result previews,
   focused snapshot coverage, README usage, and physical-device acceptance steps.
4. Run portable tests, source/format checks, and local workflow validation. Deliver
   through a PR with required current-head SwiftPM/iOS CI, unsigned IPA packaging,
   and focused English/Chinese iPhone/iPad snapshots. Primary accepts screenshots.

Physical Files-provider selection, cloud-file access, real TV writes/conflicts,
network interruptions, VoiceOver, and backgrounding remain device acceptance.
The focused uploads snapshot scope captures seven states across eight device,
appearance, and text-size combinations (56 images per language).

Local checks: 379 portable tests pass, including 16 new queue tests. Swift 6.2.4
source parsing, matching localized format validation, YAML/bash syntax, full SHA
action pins, and dry-run capture matrices pass. Native builds and screenshots
are checked during PR delivery; they do not replace physical-device acceptance.
No merge, version/tag, or release is part of this implementation batch.
