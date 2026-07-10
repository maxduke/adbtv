# Hardware Release Checklist

Use this checklist for every candidate build. Automated loopback tests cover protocol framing, mutual TLS, encrypted shell streams, and encrypted APK installation, but they do not replace an iPhone and Android TV test.

## Test Record

- Commit:
- IPA workflow run:
- iPhone or iPad model:
- iOS or iPadOS version:
- Android TV device and model:
- Android TV version:
- Network and router notes:
- Tester and date:

Record failed steps with the complete Diagnostic Detail and whether retrying changed the result. Do not include pairing codes, private keys, provisioning profiles, or other credentials.

## Build And Launch

- [ ] Build the app from a clean checkout using the README command.
- [ ] Package the unsigned IPA with GitHub Actions.
- [ ] Sign and install the IPA using the tester's normal sideloading workflow.
- [ ] Launch on iPhone and iPad layouts without clipped or overlapping controls.
- [ ] Confirm camera and local-network permission text identifies why access is needed.

## Pairing Code

- [ ] Discover an active `_adb-tls-pairing._tcp` service automatically.
- [ ] Pair using the six-digit code shown by Android Wireless Debugging.
- [ ] Match the paired device to its `_adb-tls-connect._tcp` service automatically.
- [ ] Save the Managed Device once without creating a duplicate entry.
- [ ] Cancel an active pairing attempt and start a new attempt successfully.
- [ ] Enter an incorrect or expired code and confirm a clear User Error plus technical detail.
- [ ] Pair using manual host, pairing port, and connection port fallback.

## QR Pairing

- [ ] Scan a valid Android Wireless Debugging QR code in portrait orientation.
- [ ] Scan in landscape orientation and verify the camera framing remains usable.
- [ ] Deny camera access and confirm the app explains the failure and retains Pairing Code fallback.
- [ ] Scan an unrelated QR code and confirm it is ignored.
- [ ] Complete pairing after scanning and save the matching connect service.

## Reconnect And Device Library

- [ ] Force-quit and relaunch the app, then reconnect without pairing again.
- [ ] Install a build signed by the same team and bundle identifier on a second iOS device using the same Apple Account and confirm the synchronized identity reconnects without pairing again.
- [ ] If cross-device reconnect does not work, record iCloud Keychain state, signing team, bundle identifier, elapsed sync time, and Diagnostic Detail.
- [ ] Restart Wireless Debugging so its port changes, then reconnect through the saved Bonjour service.
- [ ] Restart the Android TV and reconnect after discovery returns.
- [ ] Add at least two Managed Devices and switch between them without mixing endpoints.
- [ ] Remove one device and confirm other saved devices remain.
- [ ] Confirm no pairing secret or install history appears in app storage or UI.

## Android TV Remote

- [ ] Send D-pad up, down, left, and right.
- [ ] Send select, back, home, menu, and settings.
- [ ] Send volume up and volume down.
- [ ] Send power and verify the device-specific behavior is understandable.
- [ ] Send text containing spaces, punctuation, and non-ASCII characters to a focused text field.
- [ ] Disconnect the TV and confirm every failed action provides a User Error and technical detail.

## APK Installation

- [ ] Install a known-good signed single APK selected from Files.
- [ ] Observe determinate byte progress during transfer.
- [ ] Install the same package again and confirm replacement succeeds.
- [ ] Install a known-good APK from a direct HTTPS URL.
- [ ] Enter an HTTP URL and confirm the insecure-transport warning appears before install.
- [ ] Install from a local HTTP server when local-network permission is granted.
- [ ] Select a renamed non-APK file and confirm validation fails before transfer.
- [ ] Test an invalid signature or incompatible APK and confirm Package Manager detail is shown.
- [ ] Confirm the temporary remote APK is removed after success and failure.
- [ ] Confirm no persistent install-history screen or record is created.

## Permission And Network Failures

- [ ] Deny local-network permission and confirm discovery failure is actionable.
- [ ] Add a valid endpoint manually while discovery is unavailable.
- [ ] Test devices on an isolated guest network or VLAN and confirm timeout detail identifies the endpoint.
- [ ] Restore network access and retry without relaunching the app.

## Release Decision

- [ ] All required checks pass on at least one physical iPhone and one Android TV device.
- [ ] Pairing, discovery, and reconnect pass on a second Android TV version or device.
- [ ] GitHub Actions SwiftPM tests, simulator build, and unsigned IPA packaging are green for the tested commit.
- [ ] Every failure found above is fixed, documented as a known limitation, or explicitly accepted before the draft PR is marked ready.
