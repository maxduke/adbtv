# Release Process

ADB TV publishes unsigned IPA files for users to sign through their own sideloading workflow. GitHub releases never contain certificates, provisioning profiles, or pre-signed device builds.

## Release gates

Before tagging a release:

1. Merge only changes whose required SwiftPM and simulator checks pass.
2. Run every applicable item in the [hardware release checklist](./hardware-test-checklist.md) on a physical iPhone and Android TV.
3. Resolve or document every failed checklist item.
4. Confirm the bundled project license exactly matches `LICENSE`, every
   third-party notice remains present, and any license change has received
   appropriate legal review.
5. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `ADBTV.xcodeproj`.
6. Package the unsigned IPA locally or through the manual workflow and verify its checksum.

## Create a draft release

From an up-to-date `main` checkout, create and push an annotated semantic-version tag whose value matches `MARKETING_VERSION`:

```sh
VERSION=0.4.0
git tag -a "v$VERSION" -m "ADB TV $VERSION"
git push origin "v$VERSION"
```

Treat a pushed release tag as immutable. If a candidate is superseded, increment the
version and create a new tag instead of moving or replacing the existing tag.

The **iOS Draft Release** workflow:

- rejects tags outside `vMAJOR.MINOR.PATCH`;
- rejects a tag whose version differs from the built app;
- builds and validates the unsigned device app;
- creates the IPA and SHA-256 sidecar;
- creates or updates a draft GitHub release.

Inspect the draft release and its generated notes before publishing it. Publishing remains a manual action.

## Verify a downloaded IPA

Keep the IPA and checksum file in the same directory:

```sh
shasum -a 256 -c ADBTV-unsigned.ipa.sha256
unzip -t ADBTV-unsigned.ipa
```

A valid checksum proves the downloaded bytes match the release asset. It does not sign the app; users must still apply their own valid certificate and provisioning profile.
