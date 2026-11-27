# Warrantra hand-over (2026-11-22)

Read this first, then `docs/ANDROID_SETUP.md` (the full Android guide).
Platform focus: **Android only** for now (no Apple sign-in, no iOS push).

## Rules for whoever continues
- Never print, paste or commit secrets. `backend/.env`, `app/env/dev.json`,
  `app/android/key.properties` and `~/warrantra-upload.jks` stay local.
  When checking env vars, list **names only**.
- Typing passwords, API keys, bank/tax details and secret JSON into websites is the
  **user's** job. You may move non-secret values (Firebase project ID, SHA-1
  fingerprints, the RevenueCat `goog_` public key, Google Web client ID).
- Ask the user before: accepting terms, publishing/rolling out releases, creating
  accounts/keys, downloading files, anything that costs money.
- The Ops Console (`ops-console/`) belongs to a separate session; don't commit it.
  A test superadmin `ops-console-test-e30aa8@example.com` exists on the live DB (user chose to keep it).

## Accounts and IDs (not secret)
| Thing | Value |
|---|---|
| Android package | `com.warrantra.app` |
| Play developer account | **Codux Inc.** (ID 7862735002458823538), Chrome signed in as wearedjbros3@gmail.com (`/u/3/`) |
| Play app | "Warrantra: Warranty Tracker", app ID 4972349054045250063, Free, en-US |
| Play Console base URL | `https://play.google.com/console/u/3/developers/7862735002458823538/app/4972349054045250063/` |
| Firebase project | `warrantra-6b9c2` under codux.connect@gmail.com (`console.firebase.google.com/u/4/`), Analytics/Gemini off |
| Firebase Android app | `1:484217401773:android:c0ec4205dc64ff50157124` |
| SHA-1 Play app signing | `8A:93:F8:EA:FE:5B:48:D2:8F:D4:28:E3:C9:38:0C:03:0D:5F:75:DB` |
| SHA-1 upload key | `BD:CA:E2:CA:B2:DA:D5:80:21:05:06:6B:D4:0B:0D:F6:F9:B7:B0:DD` |
| SHA-1 debug key | `E6:EC:BB:65:E4:98:A1:B4:D2:37:F1:98:EB:C5:C3:61:E4:0C:68:4A` |
| API | `https://warrantra-api-production.up.railway.app` (health: `/healthz`) |
| Railway | project `warrantra`, services `warrantra-api` + `warrantra-worker`; Railway CLI is linked in `backend/` |
| Supabase | project ref `nmyvkascgncnvsvxpvtu` |
| Pricing | Pro **$7.99/month**, **$79.99/year** (live DB price test also has $9.99/$99.99 as option B) |

## Done
- Backend complete and deployed; Flutter app complete (clean architecture), all screens, dark/light, 177 tests pass.
- Prices lowered to $7.99 / $79.99 (committed, on `main`, live DB migrated).
- Firebase project + Android app; `app/android/app/google-services.json` in place; all 3 SHA-1s added.
- Push: app side wired (`lib/core/push/push_service.dart`, `lib/app/device_registration.dart`,
  "deadlines" channel in `MainActivity.kt`, permission asked after first saved item).
  Server side live: `PUSH_PROVIDER`, `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON` set on **both**
  Railway services and in `backend/.env`; both redeployed healthy.
- Release signing: `app/android/key.properties` + `~/warrantra-upload.jks` exist; Gradle reads them.
- Play: app created; first signed bundle (1.0.0, versionCode 1) uploaded to **Internal testing as a DRAFT** (not rolled out).
- Google Payments merchant account set up by the user.
- Play subscription **`warrantra_pro`** ("Warrantra Pro") with **active** base plans `monthly` (US$7.99) and
  `annual` (US$79.99), prices converted for all 178 countries. No subscription benefits text yet (optional).

## Not committed yet (current branch `app/design-pass`)
Android package rename, Firebase/push code, release signing, `google-services.json`,
`backend/scripts/set-fcm-env.sh`, `docs/HANDOFF.md`. Commit only `app/` (excluding build
output), `backend/scripts/set-fcm-env.sh` and `docs/`; never `backend/src/app.ts` (stray blank line),
`ops-console/`, `.claude/`. Then merge to `main` the way previous commits were
(`git merge-tree --write-tree` + `git commit-tree` + push; don't switch branches, the
ops session shares the folder). Ask the user before committing.

## Next steps, in order
1. ~~Base plans~~ done. Optional: add subscription benefits text on Warrantra Pro.
2. ~~Testers~~ done 2026-11-22: list "Warrantra testers" (user's phone Gmail) on Internal testing + Licence testing. Play app lives in developer account **Codux Inc.** (Chrome profile /u/3). Was: ask the user for the Gmail on their Android phone → Internal testing → Testers →
   Create email list → add it. Add the same Gmail under Setup → **License testing**.
   Then ask before **rolling out** the draft internal release.
3. **Billing = Google Play directly (RevenueCat dropped 2026-11-22).** Code: app `lib/features/settings/data/play_billing.dart`
   (`in_app_purchase`; sends each token to `POST /v1/me/purchases/google-play` before completing it), backend
   `services/billing/billing.service.ts` + `reconcile.ts` (Android Publisher API v2, acknowledges, revenue facts),
   RTDN webhook `POST /v1/webhooks/google-play` (Pub/Sub push, verified by Google-signed OIDC token), migration
   `20261122000023_google_play_billing.sql`. Uses the FCM service account (`firebase-adminsdk-fbsvc@warrantra-6b9c2…`);
   no new secrets. Done in consoles (Firebase/GCP project lives under Chrome account **/u/4**, Play under **/u/3**):
   Android Publisher API enabled; Pub/Sub topic `projects/warrantra-6b9c2/topics/play-rtdn` (Publisher granted to
   `google-play-developer-notifications@system.gserviceaccount.com`); push subscription `play-rtdn-push` →
   `https://warrantra-api-production.up.railway.app/v1/webhooks/google-play`, auth = the FCM service account, never
   expires; Play → Monetisation setup → RTDN enabled with that topic.
   **Left:** (a) user clicks **Invite user** in Play → Users and permissions for the service account (form was filled:
   View app info, View financial data, Manage orders and subscriptions; the agent may not grant access);
   (b) commit + deploy backend and run `npm run db:migrate`; (c) Play → Monetisation setup → **Send test notification**
   and check `billing_events` gets a `TEST` row. Google can take up to ~24h before a newly invited service account works.
4. Bump `version:` in `app/pubspec.yaml` (e.g. `1.0.0+2`), build
   `cd app && flutter build appbundle --release --dart-define-from-file=env/dev.json`
   (64 MB: the user must drag it into Play; Chrome upload tool limit is 10 MB), roll out to internal testers.
5. On a phone: install via the internal test link, sign up, add an item → allow notifications,
   test a purchase with the license-tester account, confirm plan becomes Pro.
6. **Google sign-in (native)**, set up 2026-11-22 in GCP project warrantra-6b9c2 (Chrome /u/4): Google Auth Platform
   configured (External, **Testing** status; test user = the user's phone Gmail). OAuth clients: Web "Warrantra server"
   `484217401773-oprt7s7e7u3oihukl2ika8a8odbmuiop.apps.googleusercontent.com` (redirect = Supabase `/auth/v1/callback`;
   saved in `app/env/dev.json` as `GOOGLE_SERVER_CLIENT_ID`), and 3 Android clients for `com.warrantra.app` (Play signing,
   upload, debug SHA-1s). 2026-11-27: Play builds failed with UNREGISTERED_ON_API_CONSOLE because Play now signs with
   SHA-1 D5:5E:0B:0C:1F:16:AF:80:5F:E2:6C:CB:87:90:AC:C5:D1:0D:9B:F9 (read from the installed APK), which none of the
   clients had; added client "Warrantra Android (Play signing, current)" with it. Supabase → Google provider **enabled** with that Client ID (no secret needed for native
   sign-in; add it only if web OAuth is ever used). To open sign-in to everyone: host a
   privacy policy + homepage (warrantra.app doesn't resolve yet), add them on Branding, then Audience → Publish app.
   Optional still: email via Resend (guide step 6), Ops Console finish/commit.

## Useful commands
```bash
cd app && flutter analyze && flutter test                       # 177 tests
cd app && flutter build apk --debug --dart-define-from-file=env/dev.json
cd backend && npm run db:status                                 # migrations
cd backend && railway variables --service warrantra-api --kv | cut -d= -f1   # names only
curl -s https://warrantra-api-production.up.railway.app/healthz
```

## Live Android test 2026-11-26 (emulator `Warrantra_Pixel`, user's real account)
Fixed and re-checked on the emulator 2026-11-27 (188 app tests, 37 backend tests pass). App + docs merged to main;
the backend VAT fix is committed on branch app/design-pass only (main auto-deploys to Railway):
- Confirming an estimated warranty failed ("Check the Accept estimate field"): `accept_estimate` sent only for estimates;
  months checked 1–1200. Verified: 24 → 36 months, "I confirmed it", saved, card shows "Date confirmed".
- Claim status on the item page stayed "Sent": claim updates refresh item pages. Verified: shows "Resolved · Bosch".
- Cancelled returns vanished and "Add a return window" was hidden: now a "Return · Cancelled" row plus the add link. Verified.
- Return wording ("A fixed date you entered", "the store's terms (Currys)"). Item header shows category ("BOSCH · APPLIANCES"). Verified.
- Onboarding: last page's "Get started, free" opens sign-up; header no longer jumps when Skip hides.
- Pills and choice chips restyled (radius 10, filled accent + check when selected). Verified on registration, filters.
- Receipt scan warns when the exact file is already in the Vault ("Read it anyway" / cancel deletes the copy).
  Note: "Choose from photos" re-compresses (quality 85), so a photo-picker copy and a file-picker copy of the same
  receipt have different bytes and are NOT duplicates. Server check verified via Vault upload ("You already had this exact file").
- Vault rows show the date; ALL-CAPS receipt names are title-cased on review (`productName`); fryer icon; Items header
  no longer repeats the Free count.
- Server (backend/src/lib/money.ts `linesIncludeTax`): VAT-inclusive receipts no longer get tax added again. NOT DEPLOYED.
Still to do (ask the user first):
1. Deploy backend: merge the "Don't add VAT twice" commit from app/design-pass into main; also needs the other session's uncommitted test-push route (`/v1/me/devices/test-push` → "Route not
   found" today) and `npm run db:migrate` for `20261123000024_timeline_order.sql` (same-day timeline is still jumbled:
   "Claim resolved" listed before "Claim ready to submit").
2. Terms/Privacy links point to warrantra.app, which doesn't exist yet (needs the website).
3. Paywall fallback prices show $ for a GBP account (only when Play prices don't load).
Test data left in the account: an unlinked duplicate "currys_receipt.jpg" in the Vault and a receipt-scan draft
(created 2026-11-27 while testing duplicates; 2 of 3 trial AI reads now used).
