# ADB TV

ADB TV is a native SwiftUI iOS app in progress for managing Android TV devices over Wireless Debugging using a native ADB client.

## Status

The project is in an early protocol and app-shell phase. It currently builds as Swift packages:

- `ADBClientCore`: native ADB packet, stream, shell, sync, remote-control, and APK install foundations.
- `ADBTVApp`: initial SwiftUI app shell and value models for device selection and APK install readiness.

No Xcode app project or signing workflow has been scaffolded yet.

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

## Planning Docs

- [Domain glossary](./CONTEXT.md)
- [Development flow](./docs/development-flow.md)
- [Initial architecture plan](./docs/initial-architecture-plan.md)
- [Risk mitigation plan](./docs/risk-mitigation-plan.md)
- [Architecture decision records](./docs/adr/)

## Development

The current implementation is a Swift package that contains the protocol core plus the first SwiftUI app-shell module.

On a machine with Swift 5.9+ installed:

```sh
swift test
```

The package currently contains `ADBClientCore` and `ADBTVApp`. GitHub Actions runs the same test command on macOS.
