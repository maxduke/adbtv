# ADB TV Input

ADB TV Input is the optional Android IME used for Chinese and other Unicode remote text. It has no launcher, network permission, persistent data, or third-party runtime dependency.

The explicit text receiver requires `android.permission.DUMP`, so ordinary Android applications cannot invoke it. ADB TV calls it through the authenticated ADB shell, temporarily selects this IME, commits UTF-8 text to the focused input connection, and restores the previous IME.

GitHub Actions builds and tests this module with JDK 17, Gradle 9.1.0, Android Gradle Plugin 9.0.1, and Android SDK 36. The resulting debug-signed APK is copied to `Apps/ADBTViOS/Resources/ADBTVInput.apk` and committed so a clean Xcode checkout can package the complete iOS app without requiring an Android toolchain.

To build it manually with those tools installed:

```sh
gradle -p Android/ADBTVInput testDebugUnitTest assembleDebug --no-daemon
```

Debug signing is sufficient because the helper is sideloaded over the user's authenticated ADB connection and is not distributed through an Android app store. If the helper protocol changes incompatibly, use a new package name so an older debug-signed helper cannot be mistaken for the new protocol.
