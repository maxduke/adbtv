# Check side-effecting shell command status

## Context

ADB's shell stream reports bytes and stream closure, but the initial shell protocol used by ADB TV does not carry a separate process exit code. A command can therefore return normally at the transport layer after failing on Android.

This matters for operations with side effects. In particular, treating `mkdir` or `rm` as successful without checking their status can start an APK transfer without a usable staging directory or report cleanup while leaving the temporary APK on the Managed Device.

## Decision

Use a reusable checked-shell invocation for side-effecting commands whose success is not already represented by a domain-specific response.

The invocation appends a uniquely named exit-status trailer, validates and removes it from successful output, and treats missing, malformed, or nonzero status as an error. Diagnostic output is bounded.

APK staging-directory preparation, temporary-file cleanup, and device-property probes use checked-shell invocations. Cleanup failures remain attached to an earlier transfer or install execution failure so the original failure is preserved without hiding the cleanup risk.

Keep `pm install` under `ADBAPKInstallResult` parsing because its `Success`, `Failure [...]`, and `Error:` output is part of the install domain result shown to the user.

## Consequences

- APK transfer does not begin when remote staging preparation fails.
- Successful cleanup is proven by the Android shell status instead of inferred from stream closure.
- Manual and post-pairing verification do not save shell failure text as a device model.
- Technical details identify both an original execution failure and a subsequent cleanup failure.
- Future side-effecting shell features should use the same primitive unless they have a stronger structured result protocol.
