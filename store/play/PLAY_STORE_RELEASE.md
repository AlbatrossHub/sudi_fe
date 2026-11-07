# Sudi & Sudi Work — Play Store release handbook

Everything for the first Play Store release of the two production apps, in the
order the console asks for it. Every file named here sits in `store/play/`;
every text is ready to paste. Server: **https://manage.sdppl.com**, company
website: **https://sdppl.com**.

| | Customer app | Staff app |
|---|---|---|
| Store name | **Sudi** | **Sudi Work** |
| Package | `com.sudi.customer` | `com.sudi.work` |
| Who signs in | any customer, phone + WhatsApp code | staff accounts made by the company |
| Bundle | `build/app/outputs/bundle/customerRelease/app-customer-release.aab` | `build/app/outputs/bundle/fieldRelease/app-field-release.aab` |
| Icon | `icon-512-customer.png` | `icon-512-work.png` |
| Feature graphic | `feature-customer-1024x500.png` | `feature-work-1024x500.png` |
| Screenshots | `shot-c-*.png` | `shot-w-*.png` |

## 0. Already done / still pending

- **Upload keystore**: `~/.config/sdppl/sudi-upload-keystore.jks` (alias
  `upload`); password in `android/key.properties`. **Bank both in the company
  password manager** (`~/.config/sdppl/README-keystore.txt` repeats this).
  Both apps sign with the same upload key. On each app's first bundle upload,
  accept **Play App Signing**.
- **Signed bundles** build and verify (`flutter build appbundle --release
  --flavor field|customer -t lib/main_<flavor>.dart`). Version 2.1.0 (code 6).
  **Rebuild after the Firebase/push code lands** so the shipped build carries it.
- **Pending before submission**: Firebase push (in progress), the in-app
  "Delete my account" flow in the customer app, a review sign-in path for both
  apps (§5), and the two web pages going live (§3).
- **Console account**: the existing "Albatross IT Consultancy" organisation
  account (id 6051122981108481185). One task only the owner can do, deadline
  Feb 2027: the **"Declare your trader status"** banner on the console home.

## 1. Create the apps (console → Create app, twice)

- App name: `Sudi` (then `Sudi Work`) · Default language: `English (United
  Kingdom)` · **App** · **Free** · accept the declarations.

## 2. Store listings

### Sudi (customer)

Short description (≤80 chars):
> Diamond services by SDPPL: send your jangad, we collect, process and deliver.

Full description:
> Sudi is the customer app of SUPER DIAMOND PROCESSORS PRIVATE LIMITED
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

### Sudi Work (staff)

Short description:
> SDPPL staff app: pickups, office intake, job work and deliveries — offline.

Full description:
> Sudi Work is the staff app of SUPER DIAMOND PROCESSORS PRIVATE LIMITED
> (SDPPL), Mumbai. It is used by our own employees; accounts are created by
> the company and there is no public sign-up.
>
> • Pickups — collect jangads at the customer's door with a photo of every
>   page and the collection time.
> • Office — turn collected jangads into work orders and mark them ready.
> • Job work — the department's queue, with a work timer.
> • Deliveries — take parcels out and record proof of delivery with the
>   receiver's name and signature.
> • Fully offline-first: a whole day without signal syncs when the network
>   returns.
>
> This app requires an SDPPL staff account.

Both apps: Category **Business** · Contact email `info@sdppl.com` · website
`https://sdppl.com` · phone `+91 80808 09288`.

## 3. The two web pages — LIVE since 2026-11-07

**https://sdppl.com/app/privacy** and **https://sdppl.com/app/delete-account**
both answer 200 from outside (served from `/var/www/sdppl/current/app/`,
released the deploy-folder way; nginx also learned `$uri/index.html`).

## 4. App content declarations (left menu → App content, per app)

- **Privacy policy**: `https://sdppl.com/app/privacy` (both apps).
- **Ads**: No. · **Ad ID**: No. · **News**: No. · **COVID**: No. ·
  **Government**: No. · **Financial features**: "My app doesn't provide any
  financial features" (both: invoices here are the company's own billing, not
  a financial service).
- **Target audience**: 18 and over only; not appealing to children.
- **Content rating questionnaire**: category Utility/Productivity; answer No
  to everything (no violence, no user-to-user content sharing, no location
  *sharing* — the work app records location for the employer only). The IARC
  Terms of Use tick is a legal agreement — **the owner clicks it**. Expected
  result: Everyone / PEGI 3.
- **Data safety** — see §6.
- **Account deletion** (asked for Sudi because it has account creation):
  deletion URL `https://sdppl.com/app/delete-account`; in-app path Account →
  Delete my account. Sudi Work: accounts are created and removed by the
  organisation, no self sign-up.

## 5. App access (reviewer sign-in)

Both are LIVE on production (2026-11-07) and verified end to end. The
credentials are NOT in this repository: see
`~/.config/sdppl/play-review-logins.txt` and `~/.config/sdppl/review-code.txt`
on the build machine.

- **Sudi Work**: "All or some functionality is restricted" → `playreview@sdppl.com`
  + the saved password (roles: pickup/delivery, job work, office). Reviewer
  note: *"Employee-only app; the server is preset; the account sees the
  pickup/office/job-work/delivery work lists."*
- **Sudi**: *"Enter phone 9900112233, tap 'Send code on WhatsApp', then enter
  the fixed review code <saved code> on the next screen (review bypass — real
  customers receive their code on WhatsApp). The account signs into a sandbox
  customer profile."*

## 6. Data safety (declare exactly this)

Both apps: Collects data **Yes** · Encrypted in transit **Yes** · Deletion
request path **Yes** (Sudi: in-app + URL; Sudi Work: via the company).
Nothing is **shared**. Nothing is used for tracking or ads.

| Data type | Sudi | Sudi Work | Purpose |
|---|---|---|---|
| Personal info → Name, Phone number | ✓ | ✓ | Account management |
| Personal info → Other info (GST number, optional) | ✓ | — | App functionality (invoicing) |
| Photos | ✓ (jangad pages) | ✓ (jangad pages, signature) | App functionality |
| Location → Precise, foreground only | — | ✓ (pickup/delivery record) | App functionality |
| Device or other IDs (device id, push token) | ✓ | ✓ | App functionality |

(The customer build carries no location permission; only Sudi Work declares
location.)

## 7. Upload and roll out (per app)

1. Release → **Production** → create release → upload the `.aab` → accept
   Play App Signing on first upload.
2. Countries: **India**. Release notes:
   > First release of <app name> by Super Diamond Processors.
3. Fix any pre-submission errors the console lists, then **Submit**. First
   review of a new app typically takes a few days; answers to reviewer
   questions go through the console inbox.
4. After approval: staff phones with side-loaded builds must **uninstall
   once** before installing from Play (different signing key).

## 8. After both apps are live

- Mac/iOS: new App Store app for **Sudi Work** with bundle id
  `com.sudi.work` (ios/Flutter/field.xcconfig already renamed) + Firebase iOS
  apps for both bundle ids — the Mac session prompt is prepared separately.
- Remove the review OTP parameters or rotate the code if support wants it.
- Keep `~/.config/sdppl/sudi-upload-keystore.jks` + password banked; losing
  them means losing the ability to update the apps.
