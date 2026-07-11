# Risk Mitigation Plan

This plan tracks the technical risks that could derail ADB TV and how to reduce each one before investing heavily in UI or packaging.

## Risk 1: Native Wireless Debugging Pairing

**Risk**:
Modern Android Wireless Debugging pairing requires protocol behavior that is not covered by normal iOS app APIs out of the box. SPAKE2 support is the likely missing cryptographic primitive.

**Mitigation**:
- Make pairing the center of Milestone 1, not a later feature.
- Start with Pairing Code only; add Pairing QR Code after the same protocol works.
- Build `ADBPairing` as an isolated module with deterministic unit tests for message encoding, decoding, and state transitions.
- Use AOSP as the source of truth for protocol behavior.
- Evaluate SPAKE2 options in this order:
  1. a small pure-Swift implementation if it can be tested clearly;
  2. a narrow audited Swift package;
  3. a vendored native library only if the first two fail.

**Fallback**:
If native pairing cannot be made reliable, pause the no-helper architecture before building the full app. Do not silently switch to a helper-machine model without a new ADR.

## Risk 2: ADB TLS Identity on iOS

**Risk**:
ADB pairing and reconnect require identity material that must work with TLS and be persisted securely. iOS Keychain and Security APIs may not line up cleanly with the certificate and private-key shape expected by ADB.

**Mitigation**:
- In Milestone 1, prove key generation, certificate creation, TLS use, and persistence before building Device Library screens.
- Keep Device Credential storage behind a small `DeviceIdentityStore` interface.
- First support local Keychain storage; add Synced ADB Identity only after local reconnect works.
- Query synchronizable identities strictly and use a sync-compatible When Unlocked accessibility class.
- Write import/export tests for the exact identity data format used by the ADB client.

**Fallback**:
If iCloud Keychain sync blocks progress, ship the initial version with local-only Device Credentials and record a superseding ADR.

## Risk 3: Device Discovery Reliability

**Risk**:
mDNS discovery may vary across Android TV versions, routers, VLANs, guest networks, and iOS local-network permission states.

**Mitigation**:
- Treat Device Discovery as a convenience, not the only path.
- Implement Manual Connection in the same milestone as discovery.
- Declare required Bonjour service types in the app metadata.
- Show permission-specific User Errors when local-network access is denied.
- Bound connection attempts so unreachable manual endpoints always produce a User Error and Diagnostic Detail.
- Bound QR pairing-service and post-pairing connect-service discovery, identifying the expected service or device GUID on timeout.
- Require an authenticated reconnect and ADB device-model probe before persisting any manual-code, discovered, or QR pairing result.
- Reject stale verification callbacks so a cancelled or superseded pairing cannot save or fail a newer attempt.
- Test discovery against at least two Android TV devices or Android TV versions before calling it stable.

**Fallback**:
If discovery is unreliable, keep it as best-effort and make Manual Connection prominent.

## Risk 4: APK Installation Scope

**Risk**:
APK Installation can expand quickly: single APK, split APKs, install sessions, package conflicts, storage limits, and device-side prompts all behave differently.

**Mitigation**:
- Support only one `.apk` Install Package in the initial version.
- Validate file extension and basic APK structure before transfer.
- Split APK formats remain out of scope until single APK installation is reliable.
- Model installation as phases: download, validate, transfer, install, result.
- Report ordered byte progress for URL download and ADB transfer, with indeterminate download progress when the server does not advertise a length.
- Limit both URL and Files packages to 512 MiB before retaining them in memory.
- Download and structurally validate the package before opening the ADB connection.
- Reject non-success HTTP responses and clearly non-package text, JSON, or XML content types before device work.

**Fallback**:
If direct install service support is inconsistent, use push-to-temp plus package-manager shell command as the first compatible path.

## Risk 5: HTTP Install URL Safety

**Risk**:
HTTP is useful for local-network package hosting but provides no transport integrity or confidentiality.

**Mitigation**:
- Clearly show the Install URL before installation.
- Prefer HTTPS visually when available.
- For HTTP, show a User Error or warning before first use.
- Disable URL caching so APK bytes are not retained beyond the active installation operation.
- Add a later option for user-supplied checksum verification if HTTP installs become common.

**Fallback**:
If HTTP creates too much platform or safety friction, restrict HTTP to local-network addresses and keep HTTPS for public URLs.

## Risk 6: TV Remote Command Compatibility

**Risk**:
Some Android TV remote inputs may vary by device, OS version, or app focus. Power and settings are especially likely to differ.

**Mitigation**:
- Implement TV Remote Actions through a mapping layer, not scattered shell strings.
- Start with the most stable key events: D-pad, select, back, and home.
- Add settings, text input, volume, and power as separate tested actions.
- Record per-action failures with Diagnostic Detail.
- Bind every install and remote operation to its originating Managed Device until completion or cancellation.
- Permit only one active device operation so selection changes and stale callbacks cannot present a result under another TV.

**Fallback**:
If an action is device-specific, expose it only when supported or label it as best-effort.

## Risk 7: GitHub Actions Cannot Fully Validate Device Behavior

**Risk**:
GitHub Actions can build and run unit tests, but it cannot prove real Android TV pairing, reconnect, or install behavior without external hardware.

**Mitigation**:
- Keep protocol framing, parsing, URL validation, and operation state machines unit-testable.
- Apply cancellable operation deadlines so stalled hardware and network calls cannot leave the UI running forever.
- Keep pairing-handshake success separate from verified reconnect success in the state machine and saved-device store.
- Use simulator CI for build and non-device tests.
- Maintain the [manual hardware release checklist](./hardware-test-checklist.md) for pairing, reconnect, remote actions, and APK installation.
- Add sample Diagnostic Detail from failed hardware tests to improve error handling.

**Fallback**:
If hardware testing becomes too slow, build a local mock ADB server for protocol-level development while still treating real-device tests as release gates.

## Release Gates

Do not start a polished app UI until:

- Pairing Code works against real hardware.
- TLS reconnect works after app restart.
- One shell stream returns a real device property.
- failures produce User Error and Diagnostic Detail.

Do not call APK Installation complete until:

- Files picker install works for a known-good `.apk`.
- URL Install works over HTTPS.
- HTTP URL Install behavior is explicit and understandable.
- failure cases include copyable Diagnostic Detail.
