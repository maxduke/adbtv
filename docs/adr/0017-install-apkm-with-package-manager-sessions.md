# Install APKM bundles with Package Manager sessions

ADB TV v0.6 will accept `.apkm` bundles from Files and HTTP/HTTPS URLs. An APKM bundle is a ZIP container with a base APK, split APKs, and optional metadata; it is not itself an Android package.

ADB's `install-multiple` command is implemented by the host adb client. It creates an Android Package Manager install session, streams each APK into that session, and commits the session only after every write succeeds. Running `install-multiple` as an ordinary device shell command would not reproduce that behavior.

ADB TV will inspect APKM bundles locally with an exact, pinned ZIPFoundation dependency. The app will extract only APK entries into an operation-specific temporary directory, require exactly one `base.apk`, reject duplicate or unsafe names, cap entry count and total uncompressed bytes, and structurally validate every APK before connecting to the Managed Device.

The native ADB client will mirror adb's session flow through `cmd package`: create one replace-enabled session, stream each APK with `install-write`, then commit. Failure or cancellation will abandon the session. Local temporary files will be removed when preparation or installation ends. APKM installation will not create remote staging files.

The initial APKM implementation installs every APK contained in the selected bundle. Split selection, `.apks`, and `.xapk` remain out of scope until device validation demonstrates a concrete need.

Consequences:

- Split installation is atomic and uses Android's supported Package Manager path.
- Archive parsing and decompression are not reimplemented in project code.
- ZIPFoundation's MIT license must remain in bundled legal notices.
- APKM compatibility depends on the selected bundle containing splits compatible with the target device.
