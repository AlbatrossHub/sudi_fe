# SDPPL — App Store release handbook (customer app only)

The iOS twin of `store/play/PLAY_STORE_RELEASE.md`: every text and declaration
below says the same thing as the Play listing, in Apple's fields. This release
is the **customer app only**; SDPPL Work follows later. Server:
**https://manage.sdppl.com** · company website: **https://sdppl.com**.

| | SDPPL (customer) |
|---|---|
| App Store name | **SDPPL** |
| Bundle ID | `com.sdppl.customer` (explicit; registered on team TB642Z7K56) |
| SKU | `sdppl-customer` |
| Version | 2.1.0 (build 6) — `SDPPL.ipa`, production server baked in |
| Price / availability | Free · (decide: India only, or all countries — Play text says "for our jewellery-trade customers in India") |
| Category | Primary **Business**; no secondary |
| Age rating | Answer No to everything → 4+ |
| Copyright | 2026 SUPER DIAMOND PROCESSORS PRIVATE LIMITED |

The old TestFlight-only apps **Sudi** (`com.sudi.customer`) and **Sudi Field**
(`com.sudi.field`) are retired. Never upload to them again; they can be
removed in App Store Connect once this app is live.

## 1. Create the app record (App Store Connect → Apps → + → New App)

- Platform **iOS** · Name **SDPPL** · Primary language **English (U.K.)** —
  same as Play · Bundle ID **com.sdppl.customer** (if it shows an
  Xcode-generated label, it reads "XC com sdppl customer") · SKU
  **sdppl-customer** · Full Access.
- If Apple refuses the name "SDPPL" as taken, fall back to
  "SDPPL — Diamond Services" (the launcher icon says SDPPL either way).

## 2. Listing texts (App Information / version page)

**Subtitle** (≤30 chars):
> Diamond services by SDPPL

**Promotional text** (≤170 chars, can change without review):
> Send your jangad in moments: we collect from your address, process and
> deliver, with WhatsApp updates at every step.

**Description** (plain text; same content as the Play full description):
> SDPPL is the customer app of SUPER DIAMOND PROCESSORS PRIVATE LIMITED
> (SDPPL), Mumbai — diamond processing services such as laser inscription,
> drilling, boiling and testing.
>
> • Photograph your jangad (issue voucher), pick the services you need and
>   how many pieces, and send it in moments.
> • We collect from your address — you get a reference number at once, and
>   WhatsApp updates at pickup, processing and delivery.
> • Works offline: a jangad captured without signal sends itself when the
>   network returns.
> • Sign in with your mobile number — a WhatsApp code, no password.
>
> An SDPPL trade account is created on first sign-in. The app is for our
> jewellery-trade customers in India.

**Keywords** (≤100 chars, comma-separated, no spaces needed):
> diamond,jangad,laser,inscription,drilling,boiling,testing,jewellery,polish,SDPPL

**Support URL**: https://sdppl.com · **Marketing URL**: https://sdppl.com
**Privacy Policy URL**: https://sdppl.com/app/privacy

## 3. App Privacy (nutrition labels — mirrors Play data safety §6 and ios/Runner/PrivacyInfo.xcprivacy)

Collects data: **Yes**. Nothing is used for **tracking**; nothing is shared
with third parties. Everything below: **Linked to the user**, purpose **App
Functionality**.

| Apple data type | What it is |
|---|---|
| Contact Info → Phone Number | sign-in (WhatsApp code) |
| Contact Info → Name | account / jangad paperwork |
| User Content → Photos or Videos | jangad page photos |
| Identifiers → Device ID | device record + push token |
| Contact Info → Other User Contact Info | GST number (optional, invoicing) |

**No location** in the customer app (the Play customer listing says the same;
the binary links CoreLocation because both flavors share code, but the
customer flavor never requests it — the purpose strings stay in Info.plist,
which is allowed and required).

## 4. Age rating & other declarations

- Age rating questionnaire: **No** to every content question → **4+**.
- Export compliance: already answered in the binary
  (`ITSAppUsesNonExemptEncryption = false`, HTTPS only) — no question at
  submission.
- Content rights: the app shows only the company's and the customer's own
  content → "does not contain third-party content".
- Account deletion: in-app path **Account → Delete my account**, plus
  https://sdppl.com/app/delete-account — both live; Apple guideline 5.1.1(v)
  satisfied.

## 5. App Review information

- Contact: Hardik Anavadia · +91 80808 09288 · info@sdppl.com
- Sign-in required: **Yes** — give Apple this note verbatim:

> Sign in with phone number 9900112233, tap "Send code on WhatsApp", then
> enter the fixed review code <saved code> on the next screen. This is a
> review bypass: real customers receive their code on WhatsApp. The account
> signs into a sandbox customer profile on our production server. An SDPPL
> trade account is otherwise created on first sign-in; the app serves our
> jewellery-trade customers in India.

The review phone/code are NOT in this repo: `~/.config/sdppl/play-review-logins.txt`
and `~/.config/sdppl/review-code.txt` on the Android build machine (Om).
Verify the code signs in before submitting.

## 6. Screenshots (the only asset Apple requires)

Apple takes **6.9-inch iPhone** shots (1320×2868, portrait) and scales the
rest; iPad shots are not needed (the app is iPhone-only unless the target
says otherwise). Recreate the six Play shots on the **iPhone 17 Pro Max
simulator** against production with the review sign-in, fictional data only:

1. `shot-c-1-login` — sign-in screen
2. `shot-c-2-home` — home
3. `shot-c-3-service` — service picker
4. `shot-c-4-jangad` — jangad capture
5. `shot-c-5-reference` — reference number
6. `shot-c-6-account` — account sheet

`xcrun simctl io booted screenshot shot.png` (or ⌘S in Simulator). No status
bar doctoring needed; Android emulator shots must NOT be uploaded to Apple.

## 7. Build & upload (works today, repeat per build)

```bash
flutter build ipa --release --flavor customer -t lib/main_customer.dart \
  --export-options-plist=ios/ExportOptions.plist     # no --dart-define: production default
xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive \
  -exportOptionsPlist ios/UploadOptions.plist -exportPath /tmp/upload \
  -allowProvisioningUpdates                          # uploads via the Apple ID in Xcode
```

Bump `version:` in pubspec.yaml before each new upload (Apple refuses a
reused build number). Verify before upload: bundle id `com.sdppl.customer`,
`manage.sdppl.com` in the binary, **zero** `ngrok` matches.

## 8. Known gaps / decisions

- **Push on iOS is not wired.** The Dart side ships and fails quietly (no
  plist → `Firebase unavailable` debug line, app fully functional). To light
  it up later: add an iOS app `com.sdppl.customer` to Firebase project
  `sudi-3f4bf` (sdppl15@gmail.com), drop `GoogleService-Info.plist` in
  per-flavor, add Push Notifications capability + remote-notification
  background mode, upload the APNs key to Firebase. Needs a new build +
  review, so it can ride the first update.
- **Availability**: pick India-only or worldwide at submission (§ top table).
- After approval choose **manual release** or automatic; manual recommended
  for a first release.
