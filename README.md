# ADB TV

ADB TV is a native SwiftUI iOS app in progress for managing Android TV devices over Wireless Debugging using a native ADB client.

## Status

The project is in an early protocol and app-shell phase. It currently includes a Swift package plus a native SwiftUI iOS app project:

- `ADBClientCore`: native ADB packet, stream, shell, sync, remote-control, and APK install foundations.
- `ADBTVApp`: SwiftUI app shell for saved devices, APK install sources, install state, and Android TV remote actions.
- `ADBTV.xcodeproj`: iOS app target that hosts the SwiftUI shell.

GitHub Actions currently runs Swift package tests, an iOS simulator build, and an unsigned IPA packaging workflow.

Current direction:

- iOS 17+ universal app for iPhone and iPad;
- sideloaded/open-source friendly distribution;
- no helper Mac, Linux host, Raspberry Pi, or server after installation;
- Android TV as the primary target;
- Wireless Debugging pairing by code and QR;
- multiple saved devices;
- synced ADB identity through iCloud Keychain;
- structured actions instead of raw shell in the first version;
- APK installation from Files or HTTP/HTTPS URL.

Implemented so far:

- manual saved-device entry and persistence;
- APK source selection from the iOS Files picker;
- APK source entry from a direct HTTP or HTTPS URL;
- single-APK install orchestration through the native ADB client;
- Android TV D-pad, select, back, home, and settings remote actions;
- user-facing operation status plus technical diagnostic details;
- Bonjour discovery of ADB pairing and connect services;
- AOSP-compatible TLS 1.3, TLS exporter, SPAKE2, and encrypted peer-info pairing stack;
- self-signed TLS identity generation from the synchronized ADB RSA key;
- manual Pairing Code app flow with separate pairing and connection ports, cancellation, diagnostics, and saved-device handoff;
- selectable Bonjour pairing services with device-GUID correlation and persisted connect-service handoff;
- AOSP-compatible CNXN/STLS mutual-TLS reconnect for host/port and Bonjour targets;
- loopback interoperability tests for SPAKE2, AES-GCM, TLS identity import, and TLS exporter output;
- end-to-end loopback coverage for secure reconnect and an encrypted ADB shell command;
- unsigned IPA packaging in GitHub Actions.

Still in progress:

- real-device validation of pairing, reconnect, remote actions, and APK install;
- QR camera scanning and app flow; QR payload parsing is implemented;
- text input, volume, and power remote controls.

## Planning Docs

- [Domain glossary](./CONTEXT.md)
- [Development flow](./docs/development-flow.md)
- [Initial architecture plan](./docs/initial-architecture-plan.md)
- [Risk mitigation plan](./docs/risk-mitigation-plan.md)
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

The unsigned IPA is not installable on a stock iOS device until it is signed with a valid Apple certificate and provisioning profile. GitHub Actions exposes the same packaging path through the manual **iOS Unsigned IPA** workflow.

The package currently contains `ADBClientCore` and `ADBTVApp`. GitHub Actions runs package tests, an unsigned iOS simulator build, and the manual unsigned IPA package workflow on macOS.
