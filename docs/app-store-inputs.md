# ADB TV App Store Inputs

This is a prioritized input list for a future App Store Submission Candidate.
It does not change the `0.10.1` unsigned release.

## Before First Upload

1. Replace or justify the global `NSAllowsArbitraryLoads` exception. The app
   currently permits user-entered HTTP package URLs. Apple says global ATS
   exceptions require App Review justification and recommends narrower
   exceptions. Decide whether App Store builds are HTTPS-only or retain a
   constrained local-network HTTP path.
   [Apple: NSAllowsArbitraryLoads](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads)
2. Publish a privacy policy and link it both in App Store Connect and in the
   app's About surface. Apple requires both locations for all apps.
   [Apple: App Review Guidelines 5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy)
3. Complete the App Privacy questionnaire from the actual data flow. ADB TV has
   no telemetry backend, but it handles local device addresses, camera input,
   Files selections, Photos writes, and a synchronizable ADB identity.
   [Apple: Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
4. Determine export compliance for bundled BoringSSL, TLS, RSA, AES-GCM, and
   SPAKE2 usage. Record the resulting App Store Connect declaration and add
   `ITSAppUsesNonExemptEncryption` or an approved compliance code only after
   that determination.
   [Apple: Export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
5. Decide whether Bonjour Discovery and QR Pairing ship in the App Store build.
   The unsigned configuration intentionally disables them. Verify the required
   signed capability and physical-device behavior before exposing either
   action.

## Before Review

1. Create the distribution signing, archive, validation, and TestFlight path
   without changing the existing unsigned GitHub release flow.
2. Provide review notes that explain the required Android TV setup, Wireless
   Debugging or manual ADB endpoint, pairing flow, optional helper, and how
   reviewers can exercise the app. Supply reachable test hardware or a
   practical review path if Apple requests it.
3. Prepare the product page, screenshots, support URL, age rating, category,
   copyright, and version notes from the final candidate.
4. Review the noncommercial source license and App Store distribution terms
   with qualified counsel. Keep the repository license, app notices, and any
   App Store EULA consistent.
5. Run a signed clean-install and upgrade matrix through TestFlight on physical
   iPhone/iPad hardware and Android 8, Android 10, and a modern Wireless
   Debugging target.
