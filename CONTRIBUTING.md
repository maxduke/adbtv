# Contributing to ADB TV

## Before changing code

- Search existing issues and pull requests before starting overlapping work.
- Open an issue before a large feature or protocol change so its behavior and test strategy can be agreed first.
- Never include signing certificates, provisioning profiles, Keychain exports, tokens, device identifiers, or other secrets.

## Development

Use a recent Xcode release with the iOS 17 SDK and Swift 5.9 or newer.

Run package tests:

```sh
swift test
```

Build the app without signing:

```sh
xcodebuild \
  -project ADBTV.xcodeproj \
  -scheme ADBTV \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Package the unsigned app:

```sh
scripts/package-unsigned-ipa.sh
```

Protocol and state changes should include focused tests. Changes that affect pairing, discovery, authentication, remote input, or APK installation should also update the hardware checklist when they introduce a new physical-device scenario.

## Pull requests

- Keep each commit and pull request focused.
- Explain behavior changes, dependencies, security implications, and validation performed.
- Preserve user-facing error messages plus copyable technical diagnostics.
- Record any physical Android TV and iOS versions used for validation.

By contributing, you agree that your contributions are licensed under the
[ADB TV Noncommercial Source License 1.0](./LICENSE). Contributors retain
copyright in their contributions. Do not submit code that you cannot license
under those terms.
