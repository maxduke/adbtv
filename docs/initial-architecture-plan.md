# Initial Architecture Plan

ADB TV is a native SwiftUI iOS 17 app that manages Android TV devices directly over Android Debug Bridge Wi-Fi, without a helper machine.

## Primary Risk

The project is not primarily risky because of SwiftUI. The hard part is implementing enough of modern ADB Wi-Fi natively on iOS:

1. discover `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp` services;
2. complete TLS-based pairing with the user-provided Pairing Code or Pairing QR Code secret;
3. store the resulting Synced ADB Identity in iCloud Keychain;
4. reconnect to a paired Android TV device over the TLS ADB transport;
5. open ADB streams for Structured Actions.

Until those are proven against real Android TV hardware, UI work should stay thin.

See [Risk Mitigation Plan](./risk-mitigation-plan.md) for fallback paths and release gates.

## Proposed Modules

**ADBTVApp**:
The SwiftUI app target. Owns navigation, device screens, install screens, and user-facing operation states.

**ADBClientCore**:
A Swift module for ADB protocol framing, stream multiplexing, TLS connection setup, and services such as shell and sync.

**ADBPairing**:
A Swift module for Pairing Sessions, Pairing Code entry, Pairing QR Code parsing, and pairing protocol state.

**DeviceStore**:
Stores Device Library metadata and Synced ADB Identity references. Device Credentials belong in Keychain, not normal app storage. Loading is record-resilient so one malformed entry cannot silently discard every valid Managed Device.

**Operations**:
Coordinates Structured Actions such as TV Remote Actions and APK Installation. Converts technical failures into User Errors plus Diagnostic Detail.

## Milestones

### Milestone 1: Protocol Spike

Goal: prove that an iOS process can pair with and connect to one Android TV device over Wireless Debugging.

Scope:
- Swift package or app target with a minimal protocol test harness;
- mDNS discovery for pairing and connect services;
- manual Pairing Code entry;
- TLS pairing handshake;
- store a temporary local ADB identity;
- reconnect and open a simple shell stream such as `shell:getprop ro.product.model`.

Exit criteria:
- a real Android TV device can pair;
- a later app launch can reconnect without pairing again;
- failures produce copyable Diagnostic Detail.

### Milestone 2: Minimal App Shell

Goal: turn the protocol spike into a usable SwiftUI app.

Scope:
- Device Library;
- Device Discovery screen;
- Manual Connection fallback;
- Pairing Code flow;
- basic device detail screen;
- iPhone and iPad layouts.

Exit criteria:
- users can add, save, reconnect, and remove multiple Saved Devices.

### Milestone 3: TV Remote Actions

Goal: provide the full initial Android TV remote surface.

Scope:
- D-pad;
- select;
- back;
- home;
- settings;
- text input;
- volume;
- power.

Exit criteria:
- each TV Remote Action works as a Structured Action with User Error and Diagnostic Detail on failure.

### Milestone 4: APK Installation

Goal: install a single `.apk` onto a Managed Device.

Scope:
- iOS Files picker APK Source;
- HTTP and HTTPS URL Install;
- single Install Package validation;
- transfer with Operation Progress where the underlying protocol can report it;
- install result handling.

Exit criteria:
- a selected `.apk` can be installed from Files;
- a direct Install URL can be downloaded and installed;
- no persistent install history is stored.

### Milestone 5: QR Pairing and Polish

Goal: complete the initial pairing and open-source project experience.

Scope:
- Pairing QR Code scan and parsing;
- README install/run instructions;
- GitHub Actions simulator build/test workflow;
- basic unit tests for protocol framing, QR parsing, and URL validation.

Exit criteria:
- the project can be built from a clean checkout on macOS with Xcode;
- CI verifies non-device logic;
- users can understand current limitations.

## Dependency Policy

Start with Apple frameworks where practical:

- SwiftUI for UI;
- Network.framework for TCP and Bonjour/mDNS;
- Security and Keychain APIs for identities and credentials;
- CryptoKit where it covers required primitives.

The Protocol Spike confirmed that Apple frameworks do not expose the legacy Ed25519 SPAKE2 operation required by ADB, and Network.framework cannot upgrade an established plaintext connection to ADB's in-place TLS transport. The project therefore pins Firebase's BoringSSL Swift package for SPAKE2 and the in-memory TLS engine; see [ADR 0010](./adr/0010-use-boringssl-for-adb-spake2.md) and [ADR 0011](./adr/0011-use-boringssl-for-adb-starttls.md). Apple CryptoKit remains responsible for pairing HKDF and AES-GCM.

TV text entry uses Android's built-in checked `input text` operation without requiring a companion IME; see [ADR 0012](./adr/0012-use-checked-android-input-text.md).

Side-effecting shell commands use an explicit exit-status trailer when they do not have a stronger domain-specific result. APK staging and cleanup follow this rule; see [ADR 0013](./adr/0013-check-side-effecting-shell-command-status.md).

## iOS Platform Constraints

**Local network access**:
Device Discovery needs local network permission and Bonjour service declarations. The app declares `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp`, but iOS also requires Apple's restricted Multicast Networking entitlement for these non-IANA types. The default self-signed release therefore disables Discovery and QR Pairing through an explicit build capability and retains manual Pairing Code and host/port entry.

**HTTP install URLs**:
Allowing HTTP Install URLs means the app needs an App Transport Security policy that permits the intended insecure local-network download cases. The UI should still show the source URL clearly before install because HTTP does not protect package integrity in transit.

**Camera access**:
Pairing QR Code support needs camera permission. QR pairing should remain optional because Pairing Code entry is the fallback.

**iCloud Keychain**:
Synced ADB Identity depends on Keychain synchronizable items and the right signing capabilities. Sideloaded builds may need clear setup instructions for users building with their own Apple account.

## Remaining Technical Questions

- Which Android TV versions expose Wireless Debugging and mDNS behavior consistently enough to support automatic Device Discovery?
- What integrity signal, if any, should the app require for HTTP downloads before installing an APK?

## References

- AOSP ADB Wi-Fi architecture: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/adb_wifi.md
- AOSP ADB protocol: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/protocol.md
- AOSP ADB sync protocol: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/sync.md
- AOSP pairing connection implementation: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/pairing_connection/pairing_connection.cpp
- Apple NSBonjourServices documentation: https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices
- Apple NSAppTransportSecurity documentation: https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity
- Apple kSecAttrSynchronizable documentation: https://developer.apple.com/documentation/security/ksecattrsynchronizable
