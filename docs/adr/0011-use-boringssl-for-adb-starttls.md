# Use BoringSSL for the ADB in-place TLS upgrade

## Status

Accepted.

## Context

After pairing, Android Wireless Debugging reconnect begins as plaintext ADB. The device requests `STLS`, the client acknowledges it, and both peers continue on the same TCP connection using mutual TLS 1.3. The device then sends its normal ADB `CNXN` packet inside the encrypted channel.

Network.framework configures TLS when a connection is created and does not expose an API to convert an already-established plaintext byte stream into TLS in place. Opening a second connection would not implement the ADB protocol and would lose bytes already buffered after `STLS`.

The project already pins Firebase's BoringSSL Swift package for ADB SPAKE2. Its SSL APIs can operate with memory BIOs, allowing the app to feed and drain encrypted bytes while retaining ownership of the existing `NWConnection`.

## Decision

Use the pinned BoringSSL package to implement a TLS 1.3 client and server engine behind the project-owned `CADBPairingCrypto` C API. `ADBTLSByteTransport` pumps BoringSSL memory-BIO input and output through the existing `ADBNetworkTransport` and preserves bytes received at the plaintext-to-TLS boundary.

Use the synchronized RSA ADB identity as the mutual-TLS client certificate and private key. Accept the Android device's self-signed peer certificate because possession of the paired ADB identity is the trust relationship defined by Wireless Debugging; do not substitute normal public-PKI hostname validation.

## Consequences

- Pairing and secure reconnect use one exact-pinned cryptographic dependency and one narrow project-owned bridge.
- The native ADB client can perform `CNXN`, `STLS`, TLS handshake, encrypted `CNXN`, shell, sync, and APK installation on one TCP connection.
- Memory-BIO pumping, certificate handling, handshake boundaries, and trailing bytes require dedicated unit and loopback integration tests.
- BoringSSL updates must be reviewed against both SPAKE2 and TLS behavior before changing the pin.
