# Hardware Release Checklist

Use this checklist for every candidate build. Automated loopback tests cover protocol framing, mutual TLS, encrypted shell streams, and encrypted APK installation, but they do not replace an iPhone and Android TV test.

The default unsigned IPA is intended for self-signing and uses manual host and port entry. Automatic Bonjour discovery and QR pairing are applicable only when the build is signed with Apple's approved Multicast Networking entitlement and a matching provisioning profile. Mark those entitlement-only checks as not applicable for self-signed candidates.

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
- [ ] Confirm the ADB TV icon appears correctly on the Home Screen, in Settings, and in the app switcher.
- [ ] Cold-launch in light and dark appearance and confirm the launch screen transitions without a contrasting flash.
- [ ] Launch on portrait iPhone and iPad layouts without clipped or overlapping controls.
- [ ] Confirm camera and local-network permission text identifies why access is needed.
- [ ] Open **About**, confirm the candidate version and build, and open the bundled legal notices.

## Pairing Code

- [ ] In a self-signed build, confirm Discovery and QR Pairing are hidden while **Pair with Code** and **Add Manually** remain available.
- [ ] Open **Add Device**, choose **Pair with Code**, and pair using the TV's host, pairing port, six-digit code, and connection port.
- [ ] Confirm **Verifying the TV connection** appears before the paired device is saved.
- [ ] Confirm verification reads the real TV model and saves the Managed Device once without creating a duplicate entry.
- [ ] Make the connection endpoint unreachable after pairing and confirm verification fails with technical detail without saving the device.
- [ ] Cancel an active pairing attempt and start a new attempt successfully.
- [ ] Enter an incorrect or expired code and confirm a clear User Error plus technical detail.
- [ ] Pair using manual host, pairing port, and connection port fallback.

### Entitlement-Enabled Discovery

- [ ] Launch a fresh app session and confirm discovery starts without tapping **Discover Devices**.
- [ ] On a fresh install, leave the Local Network prompt unanswered, then allow access and confirm discovery proceeds without tapping retry.
- [ ] Stop discovery manually and confirm it stays stopped until **Discover Devices** is tapped.
- [ ] While discovery is browsing, background and reopen ADB TV; confirm discovery resumes and services return.
- [ ] Discover active `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp` services automatically.
- [ ] Suppress the connect advertisement after pairing and confirm the wait ends with a pairing-succeeded discovery timeout.

## QR Pairing (Entitlement-Enabled Builds Only)

- [ ] Scan a valid QR code while its pairing advertisement is unavailable and confirm the pairing-service wait times out.
- [ ] Scan a valid Android Wireless Debugging QR code in portrait orientation.
- [ ] Deny camera access and confirm the app shows complete copyable technical detail, opens iOS Settings, and retains Pairing Code fallback.
- [ ] Scan an unrelated QR code and confirm it is ignored.
- [ ] Complete pairing after scanning, verify the matching connect service, and save the device only after the ADB model probe succeeds.

## Reconnect And Device Library

- [ ] Force-quit and relaunch the app, then reconnect without pairing again.
- [ ] Confirm relaunch shows no saved-device tool page until a Managed Device passes checked reconnect and model verification.
- [ ] Select an unreachable saved device, confirm a bounded connection error replaces the tools, and confirm **Retry Connection** works after restoring the TV.
- [ ] From an unreachable saved device, open **Update Connection**, test a replacement host and port, and confirm the old endpoint remains unchanged until **Save** is tapped.
- [ ] Save a verified replacement endpoint, confirm the original name and Device Library entry are preserved without a duplicate, and reconnect successfully after relaunching.
- [ ] Verify an endpoint reporting a different TV model and confirm ADB TV warns before replacing the connection.
- [ ] Upgrade over an earlier candidate build with multiple saved devices and confirm every valid Device Library entry remains available.
- [ ] If a Device Library warning appears, confirm valid entries remain visible and the copyable Technical Details report recovered and rejected record counts.
- [ ] Install a build signed by the same team and bundle identifier on a second iOS device using the same Apple Account and confirm the synchronized identity reconnects without pairing again.
- [ ] If cross-device reconnect does not work, record iCloud Keychain state, signing team, bundle identifier, elapsed sync time, and Diagnostic Detail.
- [ ] For an entitlement-enabled build, restart Wireless Debugging so its port changes, then reconnect through the saved Bonjour service.
- [ ] For an entitlement-enabled build, restart the Android TV and reconnect after discovery returns.
- [ ] Add at least two Managed Devices and switch between them without mixing endpoints.
- [ ] Rename a Managed Device from its current name to `  Family Room  `, confirm it saves as `Family Room`, relaunch, and confirm its identity and connection are unchanged.
- [ ] Start a long APK download or install on the first device and confirm device selection, deletion, pairing, and remote controls stay unavailable until it completes or is cancelled.
- [ ] While that operation is active, attempt to select or remove its target and confirm progress remains attached to the original device; after completion or cancellation, confirm switching works normally.
- [ ] Add a port 5555 endpoint manually, approve its RSA prompt on the TV, and confirm **Connected and saved** appears.
- [ ] Reject a manual endpoint's RSA prompt and confirm the add sheet remains open with technical detail.
- [ ] Remove one device and confirm other saved devices remain.
- [ ] Confirm no pairing secret or install history appears in app storage or UI.

## Android TV Remote

- [ ] Send D-pad up, down, left, and right.
- [ ] Send select, back, home, menu, and settings.
- [ ] Send volume up, volume down, and mute.
- [ ] Send power and verify the device-specific behavior is understandable.
- [ ] Send previous, rewind, play/pause, fast-forward, next, and stop media actions.
- [ ] Collapse and expand **Media Controls** and confirm its state does not shift or overlap adjacent controls.
- [ ] Send Enter, Delete, and Tab to a focused control or text field.
- [ ] Send text containing spaces and shell punctuation to a focused text field and confirm the exact text arrives.
- [ ] Enter Chinese text, install the bundled ADB TV Input helper, focus a TV text field, and confirm the exact text arrives.
- [ ] Confirm Unicode input restores the TV's previously selected input method after success and failure.
- [ ] Trigger an Android-side `input` failure and confirm the remote status does not show **Sent**.
- [ ] Disconnect the TV and confirm every failed action provides a User Error and technical detail.
- [ ] Send an action to an unreachable TV and confirm it times out instead of remaining in progress.
- [ ] Cancel an in-flight action to an unreachable TV and confirm the interface becomes usable immediately.

## Installed Apps

- [ ] Open **Apps** and confirm user-installed package identifiers load in sorted order without system packages.
- [ ] Search by a partial package identifier and confirm the list filters without another device request.
- [ ] Launch an Android TV app and confirm its Leanback activity opens.
- [ ] Launch a phone-style app without a Leanback activity and confirm the standard launcher fallback opens it, or a clear error with Technical Details appears.
- [ ] Cancel the uninstall confirmation and confirm the package remains installed.
- [ ] Confirm uninstall for a disposable package, verify its app data is removed, and confirm the row disappears.
- [ ] Refresh after installing an app outside ADB TV and confirm the new package appears.
- [ ] Disconnect the TV during each operation and confirm the failure is bounded and exposes copyable Technical Details.
- [ ] Refresh while the TV is unreachable, tap **Cancel**, confirm the spinner stops immediately, return to the device list, and reconnect after restoring the TV.
- [ ] After an operation fails because the TV is offline, return to the device list and confirm the same saved device can be opened again.
- [ ] Start an Apps operation and confirm back navigation, device switching, Remote, Install, rename, and connection updates stay unavailable until it completes.

## APK Installation

- [ ] Install a known-good signed single APK selected from Files.
- [ ] Observe determinate byte progress during a known-length URL download and ADB transfer.
- [ ] Download from a server without `Content-Length` and confirm indeterminate progress shows received bytes.
- [ ] Cancel during download or transfer, confirm **Cancelling and cleaning up** appears before **Installation cancelled**, then retry the same source successfully.
- [ ] Make the TV unreachable during cancellation cleanup and confirm the operation ends with cleanup-specific Technical Details.
- [ ] Install the same package again and confirm replacement succeeds.
- [ ] Install a known-good APK from a direct HTTPS URL.
- [ ] Enter an HTTP URL and confirm the insecure-transport warning appears before install.
- [ ] Redirect an HTTPS APK URL to HTTP and confirm the download is rejected with downgrade-specific Technical Details before connecting to the TV.
- [ ] Redirect an HTTPS or HTTP APK URL to HTTPS on another host and confirm the download still succeeds.
- [ ] Install from a local HTTP server when local-network permission is granted.
- [ ] Return an HTTP error or HTML response from an APK URL and confirm download-specific Diagnostic Detail appears before the app connects to the TV.
- [ ] Attempt a package advertised above 512 MiB and confirm it is rejected before buffering or connecting to the TV.
- [ ] Select a renamed non-APK file and confirm validation fails before transfer.
- [ ] Test an invalid signature or incompatible APK and confirm Package Manager detail is shown.
- [ ] Confirm each attempt uses a distinct UUID-named temporary APK and that its exact path is removed after success and failure.
- [ ] Confirm no persistent install-history screen or record is created.

## Permission And Network Failures

- [ ] In a self-signed build, confirm launch does not start Bonjour or present a Local Network prompt solely for discovery.
- [ ] In an entitlement-enabled build, deny Local Network access and confirm `PolicyDenied` opens iOS Settings.
- [ ] Add a valid endpoint manually while discovery is unavailable.
- [ ] Add an unreachable endpoint manually and confirm **Connect & Save** returns a timeout with `timedOperation` and `timeoutSeconds` details.
- [ ] Test devices on an isolated guest network or VLAN and confirm timeout detail identifies the endpoint.
- [ ] Restore network access and retry without relaunching the app.

## Release Decision

- [ ] All required checks pass on at least one physical iPhone and one Android TV device.
- [ ] Manual pairing and reconnect pass on a second Android TV version or device; automatic discovery is required only for an entitlement-enabled release.
- [ ] GitHub Actions SwiftPM tests, simulator build, and unsigned IPA packaging are green for the tested commit.
- [ ] Every failure found above is fixed, documented as a known limitation, or explicitly accepted before the draft PR is marked ready.
