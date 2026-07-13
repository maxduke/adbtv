# Sync ADB identity through iCloud Keychain

ADB TV will store device trust material as a synced ADB identity so the user's paired devices can be reused across their iPhones and iPads. This improves the multi-device iOS experience, with the trade-off that revoking that identity on an Android TV may affect every iOS device sharing the synced credential.

The identity store must create and query only synchronizable keys when synchronization is enabled. It uses `kSecAttrAccessibleWhenUnlocked`, which is compatible with synchronization and limits private-key use to an unlocked device.
