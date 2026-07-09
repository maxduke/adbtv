# ADB TV

ADB TV is a planned native SwiftUI iOS app for managing Android TV devices over Wireless Debugging using a native ADB client.

## Status

The project is in product and architecture planning. No Xcode project has been scaffolded yet.

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

The SwiftUI app target has not been created yet. The current implementation starts with a Swift package for the native ADB protocol spike.

On a machine with Swift 5.9+ installed:

```sh
swift test
```

The package currently contains `ADBClientCore`, which covers ADB packet framing foundations and related tests.
