# Android setup: push notifications and Play subscriptions

Do the steps in order. Each step ends with **Where it goes**. Secret values go only
into Railway and `backend/.env`; never paste them into chat, the app, or git.

| File | Holds | In git? |
|---|---|---|
| `backend/.env` | Server secrets for running the API on your Mac (slots already added at the bottom, commented out) | No |
| Railway → `warrantra-api` and `warrantra-worker` → **Variables** | The same server secrets for production | No |
| `app/env/dev.json` | Public app build values (not secret) | No |
| `app/android/app/google-services.json` | Firebase app config (not secret) | Yes |
| `~/warrantra-upload.jks` + `app/android/key.properties` | Your Play upload key and its password | No |

Build the app with the config file:

```bash
cd app && flutter build appbundle --dart-define-from-file=env/dev.json
```

---

## Step 0: Choose the final package name (5 minutes)

The app is currently `app.warrantra.warrantra`. Once uploaded to Google Play it can
never change, and Firebase, Google sign-in and RevenueCat all use it.

Pick one, for example `app.warrantra` or `com.warrantra.app`.

**Where it goes:** tell Claude. It changes `app/android/app/build.gradle.kts`
(`applicationId` and `namespace`) and the Kotlin package folder.

---

## Step 1: Upload key and first upload to Play (30 minutes)

Google won't let you create subscriptions until an app build that uses billing has
been uploaded, so this comes first.

1. Create the upload key on your Mac. Choose a strong password and save it, with the
   file, in your password manager. Losing either means you can never update the app.

   ```bash
   keytool -genkey -v -keystore ~/warrantra-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```

2. Create `app/android/key.properties` (it is already ignored by git):

   ```properties
   storePassword=YOUR_KEYSTORE_PASSWORD
   keyPassword=YOUR_KEY_PASSWORD
   keyAlias=upload
   storeFile=/Users/YOUR_MAC_USER/warrantra-upload.jks
   ```

   Tell Claude when it exists; Claude wires release signing into Gradle without
   reading the passwords.

3. Get the upload key's **SHA-1** (needed in steps 2 and 3):

   ```bash
   keytool -list -v -keystore ~/warrantra-upload.jks -alias upload
   ```

4. Play Console → **Create app** → name "Warrantra", App, Free (subscriptions are in-app).
5. Build: `cd app && flutter build appbundle --dart-define-from-file=env/dev.json`
6. Play Console → **Test and release → Testing → Internal testing** → Create release →
   upload `app/build/app/outputs/bundle/release/app-release.aab` → add your Gmail as a tester → Save and roll out.
7. Play Console → **Test and release → App integrity → App signing**: copy the
   **App signing key certificate SHA-1** too. Google re-signs the app, so this
   fingerprint differs from yours.

**Where it goes:** nothing to paste anywhere yet; keep both SHA-1s handy.

---

## Step 2: Push notifications with Firebase (15 minutes)

Reminders are already scheduled on the server; this lets them reach the phone.

1. Go to <https://console.firebase.google.com> → **Add project** → "Warrantra"
   (Google Analytics can be off).
2. **Add app → Android**:
   - Package name: the one from step 0
   - App nickname: Warrantra
   - Debug signing SHA-1: skip, add it later under Project settings
3. Download **`google-services.json`**.
   **Where it goes:** `app/android/app/google-services.json` (or send it to Claude).
4. **Project settings → Your apps → Warrantra (Android) → Add fingerprint**: add
   **both** SHA-1s from step 1 (upload key and app signing key).
5. **Project settings → General**: copy the **Project ID**.
   **Where it goes:** `FCM_PROJECT_ID`.
6. **Project settings → Service accounts → Generate new private key** → this
   downloads a JSON file. It is secret.
   Turn it into one line:

   ```bash
   python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))" ~/Downloads/YOUR-FILE.json
   ```

   **Where it goes:** `FCM_SERVICE_ACCOUNT_JSON` (the whole one-line output).
7. Set these three, uncommented, in `backend/.env` (wrap the JSON in single quotes
   there), and in Railway on **both** `warrantra-api` and `warrantra-worker`:

   ```
   PUSH_PROVIDER=fcm
   FCM_PROJECT_ID=your-project-id
   FCM_SERVICE_ACCOUNT_JSON={"type":"service_account",...}
   ```

8. Delete the downloaded service-account file from Downloads once it is in Railway.

Then Claude adds the app side: the notification permission prompt, the device push
token sent to the server, and the "deadlines" notification channel the server uses.

---

## Step 3: Google sign-in (15 minutes, optional for the first test)

Email sign-in works without this.

1. Go to <https://console.cloud.google.com> and pick the **same project** Firebase created.
2. **APIs & Services → OAuth consent screen**: External, app name Warrantra, your
   support email, the privacy policy URL. Publish the app.
3. **Credentials → Create credentials → OAuth client ID → Web application**, named
   "Warrantra server". Copy the **Client ID** and **Client secret**.
4. **Create OAuth client ID → Android** twice: same package name, one with the
   upload SHA-1 and one with the app signing SHA-1.
5. Supabase dashboard → **Authentication → Sign In / Providers → Google** → Enable →
   paste the **Web** client ID and secret → Save. If sign-in later fails with a
   "nonce" error, turn on **Skip nonce checks** there.

**Where it goes:** the Web **Client ID** (not secret, ends in
`.apps.googleusercontent.com`) → `app/env/dev.json` as `GOOGLE_SERVER_CLIENT_ID`.
The Client secret goes only into Supabase. The Google button appears in the app
once the ID is set.

---

## Step 4: Play subscriptions with RevenueCat (about 1 hour, plus up to 24 h for Google)

Prices: **$7.99/month** and **$79.99/year** (about $6.16 and $5.07 profit per
subscriber per month after Google's 15% subscription fee).

### 4a. Create the subscription in Play Console

1. Play Console → **Monetize with Play → Products → Subscriptions → Create subscription**
   - Product ID: `warrantra_pro` (cannot be changed later)
   - Name: Warrantra Pro
2. Add **base plans**:
   - `monthly`: auto-renewing, billing period 1 month, price **US$7.99**
   - `annual`: auto-renewing, billing period 1 year, price **US$79.99**
   Let Play convert the price for other countries, then **Activate** both.
3. **Setup → License testing**: add your Gmail so your test purchases aren't charged.

### 4b. Let RevenueCat read your Play purchases

1. Go to <https://app.revenuecat.com> → create a project "Warrantra" → **Add app →
   Google Play** → enter the package name.
2. Google Cloud Console (same project) → **APIs & Services → Library**: enable
   **Google Play Android Developer API** and **Google Play Developer Reporting API**.
3. **IAM & Admin → Service accounts → Create service account** "revenuecat" →
   **Keys → Add key → JSON** → download. This file is secret.
4. Play Console → **Users and permissions → Invite new users** → the service
   account's email → app permissions: **View app information**, **View financial
   data**, **Manage orders and subscriptions** → Invite.
5. RevenueCat → your Google Play app → **Service account credentials JSON** →
   upload that file. Google can take up to 24 hours to accept it. Then delete it
   from Downloads.
6. RevenueCat → Google Play app → **Google developer notifications → Connect to
   Google** → copy the topic ID it shows → Play Console → **Monetize with Play →
   Monetization setup → Real-time developer notifications** → paste it → Save.
   This tells RevenueCat about renewals and cancellations instantly.

### 4c. Products, entitlement and offering

1. RevenueCat → **Product catalog → Products → Import** → import both base plans
   (`warrantra_pro:monthly` and `warrantra_pro:annual`).
2. **Entitlements → New** → identifier **`pro`** (exactly this; the server checks
   for it) → attach both products.
3. **Offerings → New** → identifier `default`, mark it **Current** → add packages:
   - **Annual** (`$rc_annual`) → `warrantra_pro:annual`
   - **Monthly** (`$rc_monthly`) → `warrantra_pro:monthly`

### 4d. Tell the server about purchases (webhook)

RevenueCat → **Integrations → Webhooks → Add new webhook**:
- URL: `https://warrantra-api-production.up.railway.app/v1/webhooks/revenuecat`
- Authorization header value: the **same value** as `REVENUECAT_WEBHOOK_AUTH`,
  which is already in `backend/.env` and Railway. Copy it from Railway →
  `warrantra-api` → Variables.
- Environment: Production and Sandbox.

### 4e. Keys

1. RevenueCat → **Project settings → API keys**:
   - **Google public SDK key** (starts with `goog_`, not secret)
     **Where it goes:** `app/env/dev.json` as `REVENUECAT_GOOGLE_KEY`.
   - **Secret API key** → create one (starts with `sk_`, secret)
     **Where it goes:** `REVENUECAT_SECRET_API_KEY` in `backend/.env` and Railway
     `warrantra-api`.
2. Rebuild, upload a new internal-testing release (step 1.5–1.6), install it from
   the Play test link on your phone, and buy Pro with your license-tester account.
   Your Warrantra plan should switch to Pro within a few seconds.

---

## Step 5: Railway checklist

Railway → project **warrantra** → service → **Variables** → **New variable**.

| Variable | `warrantra-api` | `warrantra-worker` |
|---|:---:|:---:|
| `PUSH_PROVIDER=fcm` | yes | yes |
| `FCM_PROJECT_ID` | yes | yes |
| `FCM_SERVICE_ACCOUNT_JSON` | yes | yes |
| `REVENUECAT_SECRET_API_KEY` | yes | yes |
| `REVENUECAT_WEBHOOK_AUTH` | already set | already set |

Railway redeploys each service after you save.

---

## Step 6: Email (optional for now)

Needed for household invites and web account deletion, and so Supabase can send
sign-up confirmations without its low built-in limit.

1. <https://resend.com> → **Domains → Add** your domain → add the DNS records at
   your registrar → wait for Verified → **API Keys → Create**.
2. `backend/.env` and Railway (both services): `MAIL_PROVIDER=resend`,
   `RESEND_API_KEY`, `MAIL_FROM`, `SUPPORT_EMAIL`.
3. Supabase → **Authentication → Emails → SMTP Settings** → custom SMTP:
   host `smtp.resend.com`, port `465`, user `resend`, password = the Resend key.

---

## What to send Claude

- The package name (step 0)
- "key.properties is ready" (step 1); never the passwords
- `google-services.json`, or "it's in place" (step 2)

The `goog_` key and the Google Web client ID go into `app/env/dev.json` yourself;
they aren't secret, so pasting them to Claude is also fine.
