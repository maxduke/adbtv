# ADB TV

ADB TV is an iOS app for managing Android TV devices over the local network using Android Debug Bridge concepts.

## Language

**Sideloaded Build**:
An iOS app build installed outside the App Store using a user's own sideloading workflow.
_Avoid_: Self-signed app, public IPA

**Android TV Device**:
An Android-powered television, streaming box, or TV dongle that is the primary management target for this app.
_Avoid_: Android device when specifically referring to the TV-first target

**Managed Device**:
An Android TV device that the app can pair with, connect to, and operate through ADB.
_Avoid_: Client, endpoint

**Wireless Debugging**:
The Android developer feature that allows ADB pairing and connections over the local network.
_Avoid_: Wi-Fi ADB when referring to Android's pairing-based flow

**Native ADB Client**:
The app's built-in implementation of the ADB client behavior needed to pair with and manage Android TV devices directly from iOS.
_Avoid_: Bundled adb, embedded adb binary

**Protocol Spike**:
The first implementation milestone that proves Wireless Debugging pairing, TLS reconnect, and a simple ADB stream against real Android TV hardware.
_Avoid_: Prototype when referring to the first required feasibility milestone

**Pairing Session**:
A short-lived setup interaction where the app and an Android TV device establish trust using Wireless Debugging.
_Avoid_: Login, authentication

**Pairing Code**:
A numeric code shown by an Android TV device during a Pairing Session and entered manually into the app.
_Avoid_: Password, PIN

**Pairing QR Code**:
A QR code shown by an Android TV device during a Pairing Session and scanned by the app to start pairing.
_Avoid_: QR login, camera login

**Device Credential**:
The stored trust material that allows the app to reconnect to a Managed Device after a successful Pairing Session.
_Avoid_: Password, token

**Synced ADB Identity**:
A Device Credential stored so it can sync across the user's iOS devices through iCloud Keychain.
_Avoid_: Shared login, account

**Device Library**:
The set of Managed Devices remembered by the app for a user.
_Avoid_: Fleet, inventory

**APK Installation**:
An ADB Operation that transfers and installs an Android application package onto a Managed Device.
_Avoid_: Sideloading when discussing iOS app distribution

**APK Source**:
A place the user provides an Android package from, initially the iOS Files picker or a direct URL download.
_Avoid_: App store, catalog

**URL Install**:
An APK Installation flow where the app downloads an Install Package from a direct URL and then installs it.
_Avoid_: Remote install

**Install URL**:
A user-provided HTTP or HTTPS URL that the app downloads as an Install Package.
_Avoid_: Feed, repository URL

**Install Package**:
The Android package artifact selected for APK Installation. It is either a Single APK or an APKM Bundle.
_Avoid_: APK when referring to split package formats

**Single APK**:
One Android application package that Android can install directly.
_Avoid_: APKM Bundle, Split APK Set

**APKM Bundle**:
An APKMirror archive containing one base APK and the Split APKs that together form one application.
_Avoid_: APK, generic ZIP archive

**Split APK Set**:
One base APK and one or more Split APKs that must be installed atomically as one application.
_Avoid_: Multiple apps

**Installed App**:
An application currently installed for the user on a Managed Device.
_Avoid_: Install Package

**Preinstalled App**:
An Installed App supplied with the Android TV system rather than installed by
the user.
_Avoid_: System Service, Built-in Service

**Disabled Preinstalled App**:
A Preinstalled App made unavailable to the current Android TV user while
remaining installed and recoverable.
_Avoid_: Startup-disabled App, Disabled Service

**Managed Disablement**:
ADB TV's authority to restore a specific Preinstalled App after initiating its
disablement on a specific Managed Device.
_Avoid_: Disable History, Disabled App

**Protected Preinstalled App**:
A Preinstalled App that ADB TV prevents the user from disabling because it
fulfills an identifiable core role or is known to be required for ADB TV
management.
_Avoid_: Safe App, Trusted App

**Operation Progress**:
User-visible status for a running ADB Operation, ideally including progress when the underlying operation can report it.
_Avoid_: Loading state when the operation has meaningful progress

**User Error**:
A short, understandable explanation of an ADB Operation failure.
_Avoid_: Exception message

**Diagnostic Detail**:
Technical failure information that can be expanded or copied when troubleshooting is needed.
_Avoid_: User error

**ADB Operation**:
An action requested by the user against a managed device through ADB, such as shell commands, APK installation, screenshots, remote input, logs, or file transfer.
_Avoid_: Command when the action is broader than a shell command

**Structured Action**:
An ADB Operation exposed as a specific app control instead of free-form shell input.
_Avoid_: Shortcut, macro

**Device Information**:
Structured Android TV properties and runtime values shown by the app, including Android version, display resolution, storage, uptime, and build identity.
_Avoid_: Diagnostics when referring to normal device facts

**TV Screenshot**:
A bounded PNG image captured from a Managed Device through ADB and presented for preview or sharing.
_Avoid_: Screen recording, camera capture

**One-shot Shell Command**:
A single user-provided command run to completion with bounded output, exit status, cancellation, and timeout. It is not an interactive terminal session.
_Avoid_: Terminal, console when referring to the operation itself

**TV Remote Action**:
A Structured Action that sends Android TV remote input such as D-pad navigation, select, back, home, settings, text input, volume, or power.
_Avoid_: Remote command

**Remote Session**:
A bounded interaction period in which the app keeps a checked connection to one Managed Device for responsive TV Remote Actions.
_Avoid_: Pairing Session, permanent connection

**Repeating TV Remote Action**:
A D-pad direction or volume adjustment sent immediately and then repeatedly while the user continues holding its control.
_Avoid_: Android long press, repeated media action

**Device Discovery**:
The app's attempt to find Android TV devices available for Wireless Debugging on the local network.
_Avoid_: Scan when referring to the overall discovery experience

**Manual Connection**:
A fallback connection flow where the user enters a device address and port when Device Discovery does not find the device.
_Avoid_: Manual discovery

**Saved Device**:
A Device Library entry kept by the user even when the app cannot currently discover or connect to the device.
_Avoid_: Bookmark, favorite
