# ADB TV

ADB TV is a native SwiftUI iOS app for managing Android TV devices over Wireless Debugging using a native ADB client.

## Status

Version [0.6.0](https://github.com/maxduke/adbtv/releases/tag/v0.6.0) is the current release with the following Swift package and native SwiftUI iOS app features:

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
- target-bound device operations that prevent cross-device status or endpoint confusion;
- synced ADB identity through iCloud Keychain;
- structured actions instead of raw shell in the first version;
- APK and APKM installation from Files or HTTP/HTTPS URL.

Implemented so far:

- manual device connection verification and persistence with clear success or failure details;
- saved-device renaming with trimmed nonempty names and atomic Device Library persistence;
- checked saved-device reconnect before Remote or Install tools are shown, with a bounded retry surface for unreachable TVs;
- verified connection repair for unreachable saved devices, with atomic endpoint replacement and duplicate protection;
- resilient Device Library loading that preserves legacy records, recovers valid entries from partial corruption, and reports rejected data without rewriting it;
- APK or APKM source selection from the iOS Files picker;
- APK or APKM source entry from a direct HTTP or HTTPS URL;
- an explicit insecure-transport warning for HTTP app-package sources;
- ordered URL download progress with known-length and indeterminate presentation;
- bounded 512 MiB package loading for URL and Files sources, with response validation;
- redirect-aware APK downloads that reject unsupported schemes and HTTPS-to-HTTP transport downgrades;
- structural APK validation as a ZIP archive containing a root `AndroidManifest.xml` before transfer;
- package preparation and validation before opening the Android TV connection;
- single-APK install orchestration through the native ADB client;
- bounded APKM extraction with safe paths, structural validation of every APK, and temporary-file cleanup;
- atomic APKM split installation through Android Package Manager sessions, with cancellation-safe session abandonment and no remote staging files;
- live URL download and acknowledged APK transfer progress with byte counts in the install UI;
- lazy ADB sync framing with at most one 1 MiB transfer batch beyond the selected APK in memory;
- explicit APK-install cancellation that retains operation ownership through bounded fresh-connection staging cleanup, with cleanup failures exposed before same-source retry;
- operation-unique remote staging with checked removal and cleanup failures preserved in technical diagnostics;
- single active install or remote operation, bound to its originating device until completion or cancellation;
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
- cancellable remote reconnect/action progress with an eight-second failure bound;
- optional repository-owned Android IME installation, bounded UTF-8 text commit retries, and interruption-safe previous-keyboard restoration for Chinese and other Unicode input;
- checked remote shell results so Android-side input failures cannot be reported as successful actions;
- searchable user and system app names and package identifiers with bounded icons and metadata from the optional Android helper, local fallback, launch, force stop, user-app uninstall, and checked command diagnostics;
- structured device information for Android version, display resolution, storage, uptime, and build identity;
- bounded binary-safe Android TV screenshots with PNG validation, preview, native sharing, and clear protected-content/device-blocked failures;
- bounded one-shot ADB shell commands with read-only diagnostic presets, cancellation, timeout, copyable output, and preserved exit status;
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

On a machine with Swift 5.9+ installed:

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

`PolicyDenied` means Local Network access is disabled; enable it in iOS Settings and retry. `NoAuth` is a distinct Bonjour capability denial and can indicate inconsistent entitlement signing. The default self-signed IPA hides Discovery and QR Pairing and keeps **Pair with Code** and **Add Manually** available because granting Local Network access does not add the restricted entitlement. The packaged app still declares both Android Wireless Debugging Bonjour service types, and the IPA build fails if those declarations are missing from the built product. If a signing tool rewrites `Info.plist`, make sure it preserves `NSBonjourServices` and `NSLocalNetworkUsageDescription`.

For a manually entered ADB endpoint, **Connect & Save** now verifies the ADB session and reads the TV model before saving. A legacy endpoint such as port 5555 may show an RSA debugging authorization prompt on the TV the first time it sees this app's Keychain identity. Accept that prompt before the connection can finish. Modern Android Wireless Debugging connection ports continue to use paired TLS.

The repository contains `ADBClientCore`, `ADBTVApp`, and the source for the optional `ADBTVInput` Android helper. GitHub Actions runs Swift package tests, iOS simulator and unsigned IPA builds, plus Android helper unit tests and APK packaging.

ASCII remote text uses Android's built-in `input text` command with checked exit status. Chinese and other non-ASCII text uses the optional bundled ADB TV Input helper because Android's built-in command cannot generate characters absent from the TV's virtual key map. Enter Unicode text, install the helper from the Remote panel once, focus a TV text field, and send again. The app temporarily selects the helper for each send and restores the previous TV keyboard afterward.

The same helper returns installed-app names, versions, install/update dates, summed APK size, icons, and Android's stopped state through a shell-only provider. APK size covers the base and split APK files, not app data or cache. When the helper is missing, the Apps list remains fully functional and falls back to package identifiers, generic icons, and an available Force Stop action. Install the versioned v3 helper from the Apps toolbar or Remote panel; if Android rejects an update signed by a different CI key, ADB TV offers to replace only the helper and retry. Unicode input continues to support v2 during migration.

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
