# Add bounded device tools

## Context

The initial app exposed Structured Actions instead of arbitrary shell input. Device management now needs richer Device Information, TV Screenshots, and direct shell access without turning the app into an interactive terminal or allowing unbounded device output to consume iOS memory.

ADB's `exec:` service preserves raw command bytes, which is required for PNG screenshots. Existing shell commands already append and parse a checked exit-status marker.

## Decision

Add a Device Tools mode with three operations:

- load structured Android, display, storage, uptime, and build information;
- capture `screencap -p` through the raw `exec:` service, cap the response at 32 MiB, and validate the PNG header and dimensions before presentation;
- run one user-provided shell command to completion, cap command output at 256 KiB, and present its exit status without treating a nonzero status as a transport failure.

Give each operation a timeout and visible cancellation. Bind it to the selected Managed Device through the existing single-operation owner. Do not persist shell commands, shell output, or screenshots.

## Consequences

- Device facts and screenshots are available without an Android helper.
- Arbitrary shell commands can modify or erase TV data with the permissions granted to ADB shell; the app does not claim to make those commands safe.
- A screenshot or shell command that exceeds its limit fails with Diagnostic Detail instead of growing memory without bound.
- The first shell interface is one-shot only. Interactive stdin, PTY state, command history, and file management remain out of scope.

## References

- AOSP ADB services: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/SERVICES.TXT
