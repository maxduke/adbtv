# ADB TV

ADB TV is a native SwiftUI iOS app for managing Android TV devices over Wireless Debugging using a native ADB client.

## Status

Version 0.12.1 is the current release with the following Swift package and
native SwiftUI iOS app features:

- `ADBClientCore`: native ADB packet, stream, shell, sync, remote-control, and APK install foundations.
- `ADBTVApp`: SwiftUI app shell for saved devices, APK install sources, install state, and Android TV remote actions.
- `ADBTV.xcodeproj`: iOS app target that hosts the SwiftUI shell.

GitHub Actions runs Swift package tests and an iOS simulator build for pull requests.
Unsigned IPA packaging and deterministic portrait iPhone/iPad layout snapshots are manual
release-candidate checks; release tags package the final IPA automatically.

Current direction:

- iOS 17+ universal app for iPhone and iPad;
- sideloaded/source-available distribution;
- no helper Mac, Linux host, Raspberry Pi, or server after installation;
- Android TV as the primary target;
- Wireless Debugging pairing by code and QR;
- multiple saved devices;
- configuration backup/restore for saved TV connections and per-user Quick Launch pins;
- target-bound device operations that prevent cross-device status or endpoint confusion;
- synced ADB identity through iCloud Keychain;
- structured actions instead of raw shell in the first version;
- APK and APKM installation from Files or HTTP/HTTPS URL.

Android compatibility:

- Android 8.0 (API 26) is the compatibility floor for helper-backed app
  metadata and Unicode input.
- Android 8.0 and Android 10.0 manual host/port connections are physically
  verified. These older releases require an already-enabled ADB TCP endpoint,
  commonly port 5555.
- Pairing Code and QR use Android's modern Wireless Debugging flow, which
  Google documents for Android TV 13 and later. OEM availability can vary;
  manual host/port remains the fallback.
- Newer Android versions use the same bounded ADB protocol and checked command
  paths, but version-specific release claims require physical validation.

Implemented so far:

- manual device connection verification and persistence with clear success or failure details;
- saved-device renaming with trimmed nonempty names and atomic Device Library persistence;
- checked saved-device reconnect before Remote or Install tools are shown, with a bounded retry surface for unreachable TVs;
- verified connection repair for unreachable saved devices, with atomic endpoint replacement and duplicate protection;
- direct first-device pairing/connection actions, persistent address/port labels, and guidance distinguishing pairing and connection ports;
- adaptive remote controls and connection summaries for accessibility text sizes, with readable light/dark accents and prominent action fills;
- English and Simplified Chinese UI, status messages, accessibility labels, and permission descriptions that follow the system language, with English fallback;
- visible remote connection recovery and distinct app loading, failure, empty, and search states that retain cached lists after failed refreshes;
- resilient Device Library loading that preserves legacy records, recovers valid entries from partial corruption, and reports rejected data without rewriting it;
- APK or APKM source selection from the iOS Files picker;
- APK or APKM source entry from a direct HTTP or HTTPS URL;
- an explicit insecure-transport warning for HTTP app-package sources;
- ordered URL download progress with known-length and indeterminate presentation;
- bounded 512 MiB file-backed package staging for URL and Files sources, with response validation;
- redirect-aware APK downloads that reject unsupported schemes and HTTPS-to-HTTP transport downgrades;
- mapped structural APK validation as a ZIP archive containing a root `AndroidManifest.xml` before transfer;
- package preparation and validation before opening the Android TV connection;
- single-APK install orchestration through the native ADB client;
- bounded APKM extraction with safe paths, structural validation of every APK, and temporary-file cleanup;
- atomic APKM split installation through Android Package Manager sessions, with cancellation-safe session abandonment and no remote staging files;
- live URL download and acknowledged APK transfer progress with byte counts in the install UI;
- file-backed single-APK transfer with at most one ADB sync frame and one 1 MiB transport batch in memory;
- owned local package staging with cleanup after validation, success, failure, cancellation, or timeout;
- staged shared-storage uploads that preserve an existing destination until transfer completes;
- sequential multi-file uploads (up to 100 files) with overall/per-file progress,
  individual conflict decisions, cancellation cleanup, and visible partial results;
- local search within the current TV folder and Name, Newest First, or Largest First ordering, with folders kept first;
- TV-side upload conflict checks with explicit replacement, bounded independent staging cleanup after interruption, and visible cleanup failures;
- cancellable folder reads and file operations, with 30-second folder/mutation and transfer-inactivity limits and a 15-minute transfer limit;
- explicit APK-install cancellation that retains operation ownership through bounded fresh-connection staging cleanup, with cleanup failures exposed before same-source retry;
- operation-unique remote staging with checked removal and cleanup failures preserved in technical diagnostics;
- single active long-running device operation, bound to its originating device until completion or cancellation;
- Android TV D-pad, select, back, home, and settings remote actions;
- user-facing operation status plus technical diagnostic details;
- bounded connection, pairing, remote-action, and APK-install operations with timeout diagnostics;
- bounded QR pairing and post-pairing discovery so missing Bonjour advertisements cannot leave the pairing sheet stuck;
- capability-gated Bonjour discovery and QR pairing that are disabled in default self-signed builds;
- AOSP-compatible TLS 1.3, TLS exporter, SPAKE2, and encrypted peer-info pairing stack;
- self-signed TLS identity generation from the synchronized ADB RSA key;
- manual Pairing Code app flow with separate pairing and connection ports, cancellation, diagnostics, and saved-device handoff;
- selectable Bonjour pairing services with device-GUID correlation and persisted connect-service handoff;
- AVFoundation Pairing QR Code scanning with Bonjour service matching and the same saved-device handoff;
- camera-permission recovery with an iOS Settings shortcut and copyable scanner diagnostics;
- authenticated reconnect and device-model verification before any paired device is saved;
- AOSP-compatible CNXN/STLS mutual-TLS reconnect for host/port and Bonjour targets;
- legacy authenticated ADB-over-TCP reconnect for manually entered endpoints such as port 5555;
- loopback interoperability tests for SPAKE2, AES-GCM, TLS identity import, and TLS exporter output;
- end-to-end loopback coverage for secure reconnect, an encrypted ADB shell command, and encrypted APK installation;
- remote text input, menu, volume, and power controls in addition to D-pad navigation;
- page-scoped Remote Sessions that reuse one checked ADB connection, preserve up to eight rapid taps in order, reconnect once without replaying uncertain actions, and remain responsive while commands are sent;
- press-and-hold D-pad and volume repeat, external-keyboard navigation, native haptics, and bounded connection diagnostics;
- optional repository-owned Android IME installation, bounded UTF-8 text commit retries, and interruption-safe previous-keyboard restoration for Chinese and other Unicode input;
- checked remote shell results so Android-side input failures cannot be reported as successful actions;
- searchable user and system app names and package identifiers with bounded icons and metadata from the optional Android helper, local fallback, launch, native TV App Settings, force stop, confirmed user-app data clearing and uninstall, and checked command diagnostics;
- incremental installed-app metadata pages that continue beyond the first 128 packages;
- user-scoped app snapshots and actions, with uninstall limited to the snapshot's Android user;
- local Quick Launch pins for up to six apps per TV/Android user, with Remote launch, reordering, removal, and checked user/package validation;
- recoverable app-name/icon loading that retains completed pages and retries failed packages;
- helper-free Active Apps snapshots with foreground state, grouped process count, bounded proportional memory, manual refresh, and no activity history;
- guarded active-user system app state, with confirmed Disable and Restore Android Default actions that preserve package data and protect critical Android roles;
- structured device information for Android version, display resolution, storage, uptime, and build identity;
- bounded binary-safe Android TV screenshots with PNG framing/CRC checks and image decoding, preview, native sharing, and guidance for blank or blocked captures;
- bounded one-shot ADB shell commands with read-only diagnostic presets, cancellation, timeout, copyable output, and preserved exit status;
- isolated checked shell execution that preserves explicit exit codes, trailing comments, and background command syntax;
- unsigned IPA packaging in GitHub Actions;
- packaged ADB TV and BoringSSL license notices with an in-app About surface;
- repository-owned app icon and accent-color assets with packaged-product validation;
- adaptive system launch-screen configuration for iPhone and iPad.

## Planning Docs

- [Domain glossary](./CONTEXT.md)
- [Contributing](./CONTRIBUTING.md)
- [Security policy](./SECURITY.md)
- [Development flow](./docs/development-flow.md)
- [Release process](./docs/release-process.md)
- [Initial architecture plan](./docs/initial-architecture-plan.md)
- [Risk mitigation plan](./docs/risk-mitigation-plan.md)
- [Hardware release checklist](./docs/hardware-test-checklist.md)
- [Architecture decision records](./docs/adr/)

## Development

The current implementation is a Swift package plus an Xcode iOS app project.

On macOS 14+ with Swift 5.9+ installed (the full package includes SwiftUI):

```sh
swift test
```

To build the iOS app for the simulator with Xcode:

```sh
xcodebuild -project ADBTV.xcodeproj -scheme ADBTV -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

To create an unsigned IPA artifact for later signing:

```sh
scripts/package-unsigned-ipa.sh
```

To regenerate the committed app icon from its deterministic source:

```sh
scripts/generate-app-icon.pl Apps/ADBTViOS/Assets.xcassets/AppIcon.appiconset/ADBTV-AppIcon.png
```

The unsigned IPA is not installable on a stock iOS device until it is signed with a valid Apple certificate and provisioning profile. GitHub Actions exposes the same packaging path through the manual **iOS Unsigned IPA** workflow.

Each packaged artifact includes `ADBTV-unsigned.ipa.sha256`. Semantic-version tags create a draft GitHub release only after the tag version matches the built app; see the [release process](./docs/release-process.md).

## Physical Device Signing

To run from Xcode on an iPhone or iPad:

1. Open `ADBTV.xcodeproj` and select the `ADBTV` target.
2. Under **Signing & Capabilities**, select your Apple development team.
3. Change `com.maxduke.adbtv` to a bundle identifier available to that team if necessary.
4. Build and run on the connected device.

The unsigned IPA supports manual IP and port entry without special Apple capabilities. Automatic discovery browses Android's non-IANA `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp` Bonjour service types. Default builds set `ADBTV_BONJOUR_DISCOVERY_ENABLED=NO`, which hides Discovery and QR Pairing. An approved developer account can add Apple's restricted [Multicast Networking entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast), sign with a matching provisioning profile, and set that build setting to `YES`. Do not enable either part when self-signing: an entitlement absent from the provisioning profile makes the signature invalid.

The ADB identity is a synchronizable, When Unlocked Keychain item. To reuse it across iOS devices, sign each build with the same team and bundle identifier, enable iCloud Keychain for the same Apple Account, and allow time for Keychain synchronization. Changing the team or bundle identifier creates a different Keychain access namespace and therefore a different ADB identity. Pairing still works without Keychain sync, but each isolated identity must be authorized separately by the Android TV.

## Troubleshooting

In Device Library, use **Backup and Restore** (the drive icon) to export a JSON
backup to Files or import one for review. Backups include device names, model and
connection metadata, and Quick Launch apps in their saved order for each TV user.
They contain device addresses and app names; keep the file private. ADB identity
keys, pairing codes, passwords, and TV app data are excluded.

Import previews every device before applying changes. Select the new devices to
add; saved UUIDs or equivalent connection endpoints are skipped, preserving their
current names, connections, and favorites. A changed Device Library invalidates
the preview and requires another review. Imported devices retain their saved IDs,
and their pins remain grouped by Android user; reconnect to the original TV and
pair again if required. Restoring never connects or runs a TV command automatically.
After a successful restore, the current Remote session closes and the TV is
deselected so the next selection performs checked reconnect.

Backup files support up to 100 devices and 1 MiB. Invalid formats, unsupported
versions, ambiguous records, and invalid pins are rejected before any writes.
Bonjour connection backups omit phone-specific interface bindings; discovery still
requires the appropriate signed build, or use **Update Connection** to set a manual
endpoint. Re-importing keeps already-restored devices, including renamed or repaired
connections. Restoring adds configuration and does not replace an existing library.

The interface follows the system's preferred app language: English or Simplified
Chinese, with English as the default fallback. Device/app names, file names,
package identifiers, technical diagnostics, and legal notices remain unchanged.
System permission prompts are localized when the app is installed with its
language resources intact.

In **Tools → Files**, search names in the current folder using the search field.
Search ignores case, accents, and character width. **Sort Files** offers **Name**,
**Newest First**, and **Largest First**; folders remain before files. Search and
sorting use the loaded listing without additional TV requests. Refresh reloads
the listing while retaining the current search and sort choice. A failed refresh
preserves cached rows and reports the connection error.

Use **Add → Upload Files** to select up to 100 files for the current TV folder.
The upload sheet shows file-count progress, the current file's byte progress,
and uploaded/skipped/unfinished results. Files are sent in selection order.
When a name already exists, choose **Replace File** for that regular file,
**Skip File**, or **Cancel** to stop the remaining uploads. Folders, links, and
other non-file items cannot be replaced. A replacement choice applies only to
that file; repeated names in the selection require another decision.

Uploads stop at the first error and do not retry automatically. Completed files
remain on the TV. Cancellation waits for the current transfer's bounded cleanup
before the results can be closed; cleanup failures include Technical Details.
Closing the results refreshes the folder. Backgrounding requests cancellation;
the queue is not saved or resumed after leaving or relaunching the app.

`PolicyDenied` means Local Network access is disabled; enable it in iOS Settings and retry. `NoAuth` is a distinct Bonjour capability denial and can indicate inconsistent entitlement signing. The default self-signed IPA hides Discovery and QR Pairing and keeps **Pair with Code** and **Add Manually** available because granting Local Network access does not add the restricted entitlement. The packaged app still declares both Android Wireless Debugging Bonjour service types, and the IPA build fails if those declarations are missing from the built product. If a signing tool rewrites `Info.plist`, make sure it preserves `NSBonjourServices` and `NSLocalNetworkUsageDescription`.

For a manually entered ADB endpoint, **Connect** verifies the ADB session and reads the TV model before saving. A legacy endpoint such as port 5555 may show an RSA debugging authorization prompt on the TV the first time it sees this app's Keychain identity. Accept that prompt before the connection can finish. Modern Android Wireless Debugging connection ports continue to use paired TLS.

The repository contains `ADBClientCore`, `ADBTVApp`, and the source for the optional `ADBTVInput` Android helper. GitHub Actions runs Swift package tests, iOS simulator and unsigned IPA builds, plus Android helper unit tests and APK packaging.

ASCII remote text uses Android's built-in `input text` command with checked exit status. Chinese and other non-ASCII text uses the optional bundled ADB TV Input helper because Android's built-in command cannot generate characters absent from the TV's virtual key map. Enter Unicode text, install the helper from the Remote panel once, focus a TV text field, and send again. The app temporarily selects the helper for each send and restores the previous TV keyboard afterward.

The same helper returns installed-app names, versions, install/update dates, summed APK size, icons, and Android's stopped state through a shell-only provider. APK size covers the base and split APK files, not app data or cache. When the helper is missing, the Apps list remains fully functional and falls back to package identifiers, generic icons, and an available Force Stop action. Install the versioned v3 helper from the Apps toolbar or Remote panel; if Android rejects an update signed by a different CI key, ADB TV offers to replace only the helper and retry. Unicode input continues to support v2 during migration.

Apps lists and actions refer to the Android user captured when the list was
loaded. Uninstall removes the app and its data for that user; other Android
users retain their installation. If the active TV user changes, refresh Apps
before acting on the new user's apps. Helper metadata is read for the same
user. Temporary metadata failures preserve loaded names and icons, continue
later pages, and offer **Retry App Details** for the failed packages.

In **Apps**, open an app's actions menu and choose **Pin to Remote**. Remote's
**Quick Launch** row holds up to six apps for each TV/Android user; **Manage**
lets you reorder or remove them. Pins stay local and survive renaming or
connection repair. Deleting the saved TV also deletes its pins. Names are saved
when available; the helper is optional and missing metadata falls back to a
package identifier and generic icon. Remote checks the current Android user
before showing pins and checks again before launching. If the TV user changes,
refresh Quick Launch; an uncertain launch is never replayed automatically.

Quick Launch loads its own icons without first opening Apps. Its disposable
on-device icon cache is bounded to 128 entries (at most 6 MiB), scoped to the saved
TV and Android user, and excluded from configuration backups. Cached icons remain
available if a later metadata refresh fails; the TV helper supplies new icons.

Screenshots preserve the exact PNG returned by the TV for preview and sharing.
PNG framing and checksums are checked before decoding. Images rejected by the
platform decoder fail clearly; black/transparent captures show a warning while
remaining shareable. Some TVs and video apps protect playback
from capture, so a black exported PNG cannot be repaired by changing the preview.
Capture the TV Home screen or Settings to distinguish playback restrictions from
a broader TV capture problem. A blank-image warning alone does not prove DRM.

Replacing a helper signed by a different key can still fail if another Android
user retains the old helper. ADB TV does not remove other users' helper data to
work around Android's device-wide APK signing rules.

App Details can open Android's native App Info screen for any installed app.
User Apps also expose a confirmed **Clear App Data** action. Clearing data
permanently removes the app's accounts, settings, downloads, and other stored
data while leaving the app installed. System Apps do not expose this action.

Active Apps is a point-in-time, helper-free view of Installed Apps with a live
process. It groups child processes by package, shows foreground state, process
count, and proportional memory, and refreshes only on request or after an app
action. Missing memory is shown as unavailable; ADB TV does not persist activity
or recommend which apps to stop.

System Apps shows Android's effective state for the active user. Open app details
to disable an eligible package or restore Android's package default. Disable
keeps the app and its data installed, but TV features or other apps may stop
working. Restore removes the per-user override; an app may remain disabled when
that is Android's default. ADB TV protects a small set of critical packages and
the active launcher, Settings app, and input method. It does not recommend
packages or certify that other OEM packages are safe to disable.

## License

The project-authored portions of ADB TV are available under the
[ADB TV Noncommercial Source License 1.0](./LICENSE). It permits personal and
internal use, requires public Corresponding Source for distributed forks, and
prohibits selling or monetizing ADB TV or a fork without separate written
permission. These terms are source-available, not OSI-approved open source.

Code first published at or before commit
`b6860809a5c2fd6cf56f4e7ade0212b8c8bafb14` remains available under the MIT
License previously granted for that code. The new license applies to the
current project-authored version and future contributions; it does not revoke
rights already granted for earlier code.

Third-party components keep their own licenses. The app bundles the exact
project and BoringSSL terms listed in
[OpenSourceNotices.txt](./Sources/ADBTVApp/Resources/OpenSourceNotices.txt), available from
the **About** screen in every packaged build.
