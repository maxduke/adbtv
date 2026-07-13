# Use checked Android input text without a companion IME

Status: Superseded for non-ASCII input by ADR 0014. The checked built-in path remains in use for ASCII input.

## Context

ADB TV needs remote text entry while preserving the no-helper architecture. Android's built-in `input text` command converts characters through the virtual keyboard's `KeyCharacterMap`. AOSP documents that this mapping can fail when the current key character map cannot generate a character, particularly for non-ASCII text.

A companion Android input method could provide broader Unicode support, but it would require users to install and enable another app on every Managed Device. That conflicts with the initial version's direct iOS-to-ADB design.

## Decision

Use Android's built-in `input text` command for remote text entry and continue to attempt Unicode input without rejecting it on iOS.

Wrap every remote action and text command with an exit-status marker. Parse and remove that marker from successful output, and treat a nonzero, malformed, or missing status as a failed TV Remote Action with bounded Diagnostic Detail.

Do not require or bundle a companion Android keyboard in the initial version.

## Consequences

- Remote actions no longer report success merely because the ADB shell stream closed normally.
- ASCII text, spaces, and punctuation remain supported through the standard Android command.
- Non-ASCII behavior varies with the Android TV virtual key character map; unsupported input produces an explicit failure instead of a false success.
- Full device-independent Unicode entry would require a future architecture decision, likely involving an Android-side component or another supported platform API.

## References

- AOSP InputShellCommand: https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/input/InputShellCommand.java
- Android KeyCharacterMap.getEvents: https://developer.android.com/reference/android/view/KeyCharacterMap#getEvents(char%5B%5D)
