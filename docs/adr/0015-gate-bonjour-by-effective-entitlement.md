# Gate Bonjour features by the effective multicast entitlement

## Context

Android Wireless Debugging advertises non-IANA Bonjour service types. iOS returns `NoAuth` when the app attempts this browse without Apple's restricted Multicast Networking entitlement. A normal self-signed provisioning profile cannot grant that entitlement, so automatically starting discovery makes the default release begin with a predictable error. QR pairing also depends on discovering the advertised pairing service after scanning.

## Decision

Read `com.apple.developer.networking.multicast` from the running task with `SecTaskCopyValueForEntitlement`. Automatically start discovery and expose Discovery and QR Pairing controls only when the effective signed entitlement is Boolean `true`.

Keep manual Pairing Code and host/port entry available in every build. Do not infer capability from source entitlements, `Info.plist`, or the provisioning profile because only the effective entitlement on the running process proves that iOS granted it.

## Consequences

- Normal self-signed builds open without an unavoidable Bonjour error and present only usable pairing paths.
- Approved builds gain automatic discovery and QR pairing without a separate app variant or runtime setting.
- A malformed or missing effective entitlement fails closed even if build inputs claimed the capability.
- `NoAuth` handling remains as a diagnostic safeguard for capability-enabled builds whose signing or platform state is inconsistent.

## References

- Apple `SecTaskCopyValueForEntitlement`: https://developer.apple.com/documentation/security/sectaskcopyvalueforentitlement(_:_:_:)
- Apple Multicast Networking entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
