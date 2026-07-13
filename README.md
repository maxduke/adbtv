# ADB TV

ADB TV is a native SwiftUI iOS app for managing Android TV devices over Wireless Debugging using a native ADB client.

## Status

The initial feature set is implemented and awaiting physical-device release validation. The repository includes a Swift package plus a native SwiftUI iOS app project:

- `ADBClientCore`: native ADB packet, stream, shell, sync, remote-control, and APK install foundations.
- `ADBTVApp`: SwiftUI app shell for saved devices, APK install sources, install state, and Android TV remote actions.
- `ADBTV.xcodeproj`: iOS app target that hosts the SwiftUI shell.

GitHub Actions runs Swift package tests, an iOS simulator build, unsigned IPA packaging,
Android input-helper tests and packaging, and deterministic portrait iPhone/iPad layout
snapshots in light and dark appearance.

Current direction:

- iOS 17+ universal app for iPhone and iPad;
- sideloaded/open-source friendly distribution;
- no helper Mac, Linux host, Raspberry Pi, or server after installation;
- Android TV as the primary target;
- Wireless Debugging pairing by code and QR;
- multiple saved devices;
- target-bound device operations that prevent cross-device status or endpoint confusion;
- synced ADB identity through iCloud Keychain;
- structured actions instead of raw shell in the first version;
- APK installation from Files or HTTP/HTTPS URL.

Implemented so far:

- manual device connection verification and persistence with clear success or failure details;
- resilient Device Library loading that preserves legacy records, recovers valid entries from partial corruption, and reports rejected data without rewriting it;
- APK source selection from the iOS Files picker;
- APK source entry from a direct HTTP or HTTPS URL;
- an explicit insecure-transport warning for HTTP APK sources;
- ordered URL download progress with known-length and indeterminate presentation;
- bounded 512 MiB package loading for URL and Files sources, with response validation;
- redirect-aware APK downloads that reject unsupported schemes and HTTPS-to-HTTP transport downgrades;
- structural APK validation as a ZIP archive containing a root `AndroidManifest.xml` before transfer;
- package preparation and validation before opening the Android TV connection;
- single-APK install orchestration through the native ADB client;
- live URL download and acknowledged APK transfer progress with byte counts in the install UI;
- lazy ADB sync framing with at most one 1 MiB transfer batch beyond the selected APK in memory;
- explicit APK-install cancellation that retains operation ownership through bounded fresh-connection staging cleanup, with cleanup failures exposed before same-source retry;
- operation-unique remote staging with checked removal and cleanup failures preserved in technical diagnostics;
- single active install or remote operation, bound to its originating device until completion or cancellation;
- Android TV D-pad, select, back, home, and settings remote actions;
- user-facing operation status plus technical diagnostic details;
- bounded connection, pairing, remote-action, and APK-install operations with timeout diagnostics;
- bounded QR pairing and post-pairing discovery so missing Bonjour advertisements cannot leave the pairing sheet stuck;
- automatic, manually restartable Bonjour discovery of ADB pairing and connect services;
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
- optional repository-owned Android IME installation, bounded UTF-8 text commit retries, and interruption-safe previous-keyboard restoration for Chinese and other Unicode input;
- checked remote shell results so Android-side input failures cannot be reported as successful actions;
- unsigned IPA packaging in GitHub Actions;
- repository-owned app icon and accent-color assets with packaged-product validation;
- adaptive system launch-screen configuration for iPhone and iPad.

Still in progress:

- real-device validation of pairing, reconnect, remote actions, and APK install;
- real-device validation of QR camera framing and permission behavior.

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

The ADB identity is a synchronizable, When Unlocked Keychain item. To reuse it across iOS devices, sign each build with the same team and bundle identifier, enable iCloud Keychain for the same Apple Account, and allow time for Keychain synchronization. Changing the team or bundle identifier creates a different Keychain access namespace and therefore a different ADB identity. Pairing still works without Keychain sync, but each isolated identity must be authorized separately by the Android TV.

## Troubleshooting

If discovery reports `NoAuth` or `PolicyDenied`, allow Local Network access in the iOS prompt. A browser waiting for that decision remains active and proceeds when iOS grants access; fatal authorization failures retry when the app becomes active after returning from Settings. The packaged app declares both Android Wireless Debugging Bonjour service types; the IPA build fails if those declarations are missing from the built product. If a signing tool rewrites `Info.plist`, make sure it preserves `NSBonjourServices` and `NSLocalNetworkUsageDescription`.

For a manually entered ADB endpoint, **Connect & Save** now verifies the ADB session and reads the TV model before saving. A legacy endpoint such as port 5555 may show an RSA debugging authorization prompt on the TV the first time it sees this app's Keychain identity. Accept that prompt before the connection can finish. Modern Android Wireless Debugging connection ports continue to use paired TLS.

The repository contains `ADBClientCore`, `ADBTVApp`, and the source for the optional `ADBTVInput` Android IME. GitHub Actions runs Swift package tests, iOS simulator and unsigned IPA builds, plus Android helper unit tests and APK packaging.

ASCII remote text uses Android's built-in `input text` command with checked exit status. Chinese and other non-ASCII text uses the optional bundled ADB TV Input helper because Android's built-in command cannot generate characters absent from the TV's virtual key map. Enter Unicode text, install the helper from the Remote panel once, focus a TV text field, and send again. The app temporarily selects the helper for each send and restores the previous TV keyboard afterward.

## License

ADB TV is available under the [MIT License](./LICENSE).
