# Prompt for the Mac session — SDPPL iOS release (give verbatim)

The Android apps are live work; iOS follows them. Repo `sudi_fe`, branch
`main` — pull first; you need the SDPPL-rename commit (after c3bac23) or later.

1. **Both apps were renamed to SDPPL / SDPPL Work with NEW bundle ids.**
   `ios/Flutter/field.xcconfig` says `PRODUCT_BUNDLE_IDENTIFIER = com.sdppl.work`,
   `APP_DISPLAY_NAME = SDPPL Work`; `customer.xcconfig` says
   `com.sdppl.customer` / `SDPPL`. In App Store Connect create TWO NEW apps,
   "SDPPL Work" (`com.sdppl.work`) and "SDPPL" (`com.sdppl.customer`). The old
   TestFlight apps under com.sudi.field / com.sudi.customer are retired — do
   not upload to them again. Register the two new explicit App IDs in
   developer.apple.com first.
2. **Firebase (push) is set up** — project `sudi-3f4bf` under the client's
   Google account (sdppl15@gmail.com). On the Mac:
   - In the Firebase console add TWO iOS apps to that project, bundle ids
     `com.sdppl.customer` and `com.sdppl.work`; download each
     `GoogleService-Info.plist`.
   - Wire them per-flavor the Xcode way (one plist per scheme, same approach
     as the per-flavor xcconfigs already in the project), add the
     Push Notifications capability + Background Modes > Remote notifications
     to both schemes, and upload the APNs key in Firebase project settings.
   - The Dart side is done (`lib/src/core/push/push_service.dart`;
     `Firebase.initializeApp()` reads the native plist). `pod install` pulls
     firebase_core/firebase_messaging.
3. **Build + upload both** (TestFlight first, then release):
   `flutter build ipa --release --flavor field -t lib/main_field.dart` and
   `--flavor customer -t lib/main_customer.dart`. Version is 2.1.0+6; bump the
   build number if App Store Connect complains.
4. **Store listing material** is in `store/play/` (texts in
   PLAY_STORE_RELEASE.md §2, icons/feature art). Take iOS screenshots on the
   simulator against https://manage.sdppl.com with the review sign-ins — ask
   Om's session for the review credentials; they are not in the repo.
5. Privacy policy URL: https://sdppl.com/app/privacy · account deletion:
   https://sdppl.com/app/delete-account (required for the customer app: it
   has open sign-up; the in-app button exists under Account).
