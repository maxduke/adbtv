# Maintenance optimization

Scope: fix and simplify the existing application after v0.12.0, without new
features, production dependencies, protocol changes, or automatic data migration.

1. Share device endpoint identity between library add/connection repair and
   configuration backup/restore. Normalize Bonjour service/domain case and domain
   dots consistently; ignore local interface bindings. Keep existing IDs, names,
   and Quick Launch data, and reject ambiguous existing archives without rewriting.
2. Store the file-browser projection separately from transfer progress. Recompute
   only when directory entries, query, sort order, or locale change. Filter app
   rows once per presentation and index Active Apps by package when snapshots
   change. Preserve ordering, search, error/empty states, and snapshot user scope.
3. Move existing root-view components into focused files without changing their
   bodies or navigation. Extract installed-app detail loading ownership into one
   domain-specific coordinator; cover cancellation, replacement, late pages and
   late completion while retaining device/user checks at the state boundary.

Validate each logic change with focused portable tests, then run the portable
suite and Swift parse/resource checks. Preserve native SwiftPM/iOS CI and inspect
existing focused snapshots for moved views and file/app lists before PR completion.
Use small commits for identity, list computation, and view/task extraction.

Device Release profiling is needed before adding image caching or claiming
on-device frame-rate improvements. Physical checks remain separate from portable
tests and deterministic simulator screenshots. Maintenance PR delivery does not
authorize another release or merge.

## Implementation and local validation

- Shared endpoint identity now prevents equivalent Bonjour records from being
  added or used as a second repair target. Existing ambiguous persisted records
  are still rejected safely by backup; no IDs, names or favorites are merged or
  deleted automatically.
- File rows are cached across unrelated view/transfer updates, with explicit
  invalidation for entries, search, sorting and locale. Active app lookups use a
  snapshot-scoped package index, retaining first-match behavior for duplicate
  input and replacing the index with each snapshot.
- Six existing view groups moved out of the root file without changing their
  bodies. Root file length falls from 5,147 to 2,890 lines. Detail loading now owns
  request identity/cancellation outside SwiftUI; state publication still verifies
  the originating device and Android user.
- 414 portable tests pass on Swift 6.2.4/Linux, including 17 added tests for
  endpoint consistency, cached-list invalidation and detail-task ownership.
  Swift parse checks pass for all app/test sources and the iOS entry point.
- Native SwiftPM/iOS compilation, Release IPA packaging and existing English/
  Chinese UI snapshots remain part of PR delivery. Portable tests establish no
  iPhone performance or physical-device acceptance result.
