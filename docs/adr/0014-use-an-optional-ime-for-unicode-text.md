# Use an optional Android IME for Unicode text

## Context

Physical Android TV testing proved that `input text` cannot inject Chinese on the tested device. Android's virtual `KeyCharacterMap.getEvents` returned `null`, and the platform command crashed while dereferencing that result. Escaping and encoding the same command cannot make an unavailable key mapping exist.

## Decision

Keep Android's checked `input text` command for ASCII. Route non-ASCII text through a repository-owned Android input method called ADB TV Input.

Build the helper from reviewed Java source with the official Android Gradle plugin and bundle the resulting APK in the iOS app. The helper has no network permission, launcher, persistent data, or third-party runtime library. Its explicit text receiver requires `android.permission.DUMP`, limiting calls to privileged system or ADB shell processes.

The iOS app offers an explicit helper installation command. For each Unicode send, it records the current input method, temporarily enables and selects ADB TV Input, and makes bounded commit attempts while the TV binds the new input method. It restores the previous input method explicitly after the attempt and through an exit/signal trap if the shell is interrupted. Every step remains covered by checked shell exit status and technical diagnostics.

## Consequences

- Chinese and other Unicode text no longer depends on a TV key-character map that cannot represent it.
- Each managed TV needs the small helper APK installed once before Unicode input.
- ASCII input and all remote buttons continue to work without the helper.
- The helper adds an Android build-time dependency, but no iOS or Android runtime library dependency.
- Physical testing must verify helper installation, IME switching, text commit, restoration, and shell-permission behavior across representative Android TV versions.

## References

- AOSP InputShellCommand: https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/input/InputShellCommand.java
- Android KeyCharacterMap.getEvents: https://developer.android.com/reference/android/view/KeyCharacterMap#getEvents(char%5B%5D)
