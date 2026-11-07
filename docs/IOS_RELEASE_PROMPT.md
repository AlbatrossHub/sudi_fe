# Prompt for the Mac session — Sudi iOS release (give verbatim)

The Android apps are live work; iOS follows them. Repo `sudi_fe`, branch
`main` — pull first; you need commit 98023a7 or later.

1. **Sudi Work is the old "field" flavor, renamed.** `ios/Flutter/field.xcconfig`
   already says `PRODUCT_BUNDLE_IDENTIFIER = com.sudi.work`,
   `APP_DISPLAY_NAME = Sudi Work`. In App Store Connect create a NEW app
   "Sudi Work" with the new bundle id `com.sudi.work` (the old TestFlight app
   under com.sudi.field is retired — do not upload to it again). The customer
   app stays `com.sudi.customer` / "Sudi".
2. **Firebase (push) is set up** — project `sudi-3f4bf` under the client's
   Google account (sdppl15@gmail.com). On the Mac:
   - In the Firebase console add TWO iOS apps to that project, bundle ids
     `com.sudi.customer` and `com.sudi.work`; download each
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
