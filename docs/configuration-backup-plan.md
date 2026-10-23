# Configuration backup and additive restore

## Scope and rules

- Export a versioned JSON backup of saved TV names, model/connection metadata,
  and Quick Launch pins grouped by TV and Android user. Never access Keychain,
  pairing codes, certificates, installation sources/history, or arbitrary defaults.
- Bound input/output to 1 MiB and 100 devices. Use an explicit allowlisted schema,
  validate connections and every pin, and reject unknown versions/fields, ambiguous
  duplicate IDs/endpoints, invalid data, and oversized files before writing.
- Preview every imported TV. Select new devices individually; skip any device
  with an already-saved UUID or equivalent endpoint, retaining the current name,
  connection, and all preferences. Do not merge or replace existing pins.
- Preserve new devices' archived UUIDs so re-import after connection repair still
  recognizes the same saved TV. Preserve Android user IDs and app order, and keep
  all existing checked reconnect/user/package validation. Restore never connects
  to a TV, changes its data, or grants pairing trust.
  After successful restore, close the old remote session and deselect the TV so
  subsequent operations pass checked reconnect even if another window changed it.
- Re-read the Device Library at apply time and reject a stale preview. Validate
  and encode the entire selected result first; stage only new pin keys, then
  commit the expanded Device Library. Roll back newly staged keys on commit error.
  If a process interruption left matching pin data under a new device UUID, adopt
  it without rewriting it; reject conflicting orphan data. Existing data stays intact.
- Offer Backup and Restore from Device Library, including an empty library. Use
  native Files export/import and a scrollable, bilingual preview/results surface.
  Bound file reads before JSON decoding; ignore cancelled/stale task results.
- No new production dependency, automatic sync, credential export, overwrite mode,
  cross-TV favorite remapping, version/tag/release, or unrelated UI-test expansion.
- Bonjour backups keep connect-service name/domain and omit local interface
  bindings, so a backup is portable between iOS devices.

## Validation and delivery

Test exact round trips and field allowlisting, bounds and malformed inputs,
endpoint/UUID duplicates, user/order isolation, selected-only restore, unchanged
existing bytes, re-import/repair, stale previews, corrupt existing data, orphan
adoption/conflict, pre-write validation, and rollback after simulated commit error.
Run the portable suite and localization/source checks locally, then deliver a PR
with current-head SwiftPM/iOS checks, unsigned IPA, and focused English/Chinese
iPhone/iPad snapshots at normal and largest text sizes. Inspect final screenshots.
The focused backup scope captures six states across eight device/appearance/text
size combinations (48 images per language).

Signed-device Files-provider access/cancellation, real reconnect and pairing,
VoiceOver, and interactive large-text navigation remain manual acceptance.

Local validation: 397 portable tests pass, including 18 new backup/restore tests.
Swift 6.2.4 parses all app/test sources. Both locales have 500 matching keys, and
format/literal-lookup checks, YAML/bash syntax, action SHA pins, and bilingual
48-capture dry runs pass. Native checks and screenshot acceptance follow in PR delivery.
