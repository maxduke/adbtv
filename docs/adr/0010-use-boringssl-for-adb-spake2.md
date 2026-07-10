# Use BoringSSL for ADB SPAKE2

## Status

Accepted.

## Context

Android Wireless Debugging pairing uses BoringSSL's legacy Ed25519 SPAKE2 protocol. The pairing password is the user-entered secret followed by 64 bytes exported from the preceding TLS connection with the `adb-label` exporter label. Apple CryptoKit supports the later HKDF-SHA256 and AES-128-GCM operations, but it does not expose the Ed25519 point operations needed for this SPAKE2 variant.

A pure-Swift implementation would require maintaining security-sensitive field and group arithmetic. The available third-party Swift ADB implementation is new, has no declared license, and does not provide sufficient independent interoperability evidence.

## Decision

Pin Firebase's Apache-2.0 `boringSSL-SwiftPM` package at version `0.41.0`. Use a small project-owned C bridge for only `SPAKE2_CTX_new`, `SPAKE2_generate_msg`, and `SPAKE2_process_msg`. Continue to use CryptoKit for HKDF-SHA256 and AES-128-GCM.

The public Swift initializer requires a 64-byte TLS exporter value and appends it to the pairing secret before creating the SPAKE2 context. This keeps the AOSP channel binding requirement explicit at the API boundary.

## Consequences

- Pairing uses the same SPAKE2 implementation family as AOSP instead of app-owned elliptic-curve arithmetic.
- The dependency adds source-build time and binary size; CI must continue to cover package and iOS builds.
- BoringSSL is isolated behind `CADBPairingCrypto`, allowing replacement without changing the pairing protocol state machine.
- TLS setup, extraction of the `adb-label` exporter, certificate identity generation, and real-device validation remain separate required work.
