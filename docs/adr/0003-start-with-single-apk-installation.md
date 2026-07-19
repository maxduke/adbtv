# Start with single APK installation

ADB TV will support installing a single `.apk` file in the initial version, with split package formats such as `.apks`, `.xapk`, and `.apkm` left for later unless they prove cheap to support. This keeps APK installation focused on the core ADB transfer and install flow before adding archive parsing, split selection, and multi-package install behavior.

APKM support is added for v0.6 by [ADR 0017](./0017-install-apkm-with-package-manager-sessions.md).
