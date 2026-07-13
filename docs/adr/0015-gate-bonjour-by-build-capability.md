# Gate Bonjour features by an explicit build capability

## Context

Android Wireless Debugging advertises non-IANA Bonjour service types. iOS returns `NoAuth` when the app attempts this browse without Apple's restricted Multicast Networking entitlement. A normal self-signed provisioning profile cannot grant that entitlement, so automatically starting discovery makes the default release begin with a predictable error. QR pairing also depends on discovering the advertised pairing service after scanning.

iOS does not expose a supported Swift API for reading the running process's effective entitlement. Source entitlements and provisioning-profile contents are also insufficient because only a correctly signed combination grants the capability.

## Decision

Add the `ADBTV_BONJOUR_DISCOVERY_ENABLED` build setting, default it to `NO`, and expose its processed value through `ADBTVBonjourDiscoveryEnabled` in `Info.plist`. Automatically start discovery and expose Discovery and QR Pairing controls only when that value is enabled.

An approved maintainer must set the build setting to `YES` only while signing with the Multicast Networking entitlement and a matching provisioning profile. Keep manual Pairing Code and host/port entry available in every build. Retain `NoAuth` handling for an opted-in build whose signing capability is inconsistent.

## Consequences

- Normal self-signed builds open without an unavoidable Bonjour error and present only usable pairing paths.
- The unsigned release workflow verifies that its packaged build keeps the capability disabled.
- Approved builds require one explicit build-setting opt-in alongside their signing configuration.
- A mismatched opt-in remains visible as actionable `NoAuth` diagnostic detail rather than silently falling back.

## References

- Apple Multicast Networking entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
- Apple entitlement diagnostics: https://developer.apple.com/documentation/bundleresources/diagnosing-issues-with-entitlements
