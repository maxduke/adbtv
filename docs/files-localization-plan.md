# File search, sorting, and English/Simplified Chinese localization

## Scope

- Search file and folder names in the currently loaded directory only. Ignore
  case, accents, and character width; preserve original names and paths.
- Offer Name, Newest First, and Largest First ordering. Keep directories first,
  use natural name ordering for ties, and never issue extra ADB requests for
  filtering or sorting. Keep refresh failures distinct from an empty directory
  or a search with no matches. Leave file-operation ownership and safety intact.
- Add English and Simplified Chinese resources, selected by the system language
  with English fallback. Cover UI labels, dynamic statuses/errors, destructive
  confirmations, accessibility labels, and iOS permission descriptions.
- Resolve app strings from the Swift package's resource bundle. Keep app/device
  names, file names and paths, package identifiers, shell/protocol tokens,
  diagnostic data, and license texts unchanged. Add no production dependency.
- Keep shortcuts, Siri, recursive search, batch operations, persistent search
  history, and unrelated refactoring outside this change.

## Implementation

1. Add a pure file-list query model, search/ordering controls, and meaningful
   filter/sort/state regression tests.
2. Add localized resources and a small package-bundle string lookup, converting
   user-facing static and formatted text without changing protocol behavior.
   Localize app permission descriptions through InfoPlist.strings.
   Use alerts with short actions for data clearing and system-state changes so
   long translated warnings remain visible at large accessibility sizes.
3. Add resource/format coverage checks and English/Chinese presentation tests.
   Update README and device acceptance guidance.
4. Run portable tests and Swift syntax checks locally, then deliver a PR with
   current-head SwiftPM/iOS checks. Inspect focused iPhone/iPad English/Chinese
   snapshots in both appearances, including large text and search empty states.

## Acceptance limits

Local verification: 363 portable Swift tests pass. After the final query/lookup
adjustments, all nine focused query/localization tests pass. App/UI and app-test
sources parse with Swift 6.2.4; YAML, shell syntax, action SHA pins, and snapshot
dry runs pass. Both language resources contain 439 matching, format-checked keys.
The focused localization matrix captures 140 images per language, including
search results/no matches, size sorting, and largest-text destructive warnings.

Static snapshots do not prove TV file actions, VoiceOver focus, keyboard input,
or system permission prompts on a signed physical device. Those remain explicit
manual acceptance items. No version/tag/release or merge is part of this batch.
