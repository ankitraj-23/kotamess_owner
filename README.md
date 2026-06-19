# KotaMess Owner

Native Flutter (Android) app for mess owners to turn WhatsApp requests into an
approvable daily meal count and a simple student ledger. It is a complete,
demo-ready MVP backed entirely by **Supabase**: email/password auth, per-owner
data isolation (Row Level Security), server-side Gemini extraction, and live
dashboard / daily-count / ledger screens.

---

## Production readiness (quick reference)

- **What it does:** turns WhatsApp chat imports into approvable daily meal
  counts plus per-customer billing, payments and a simple ledger — all isolated
  per owner in Supabase.
- **Run:** `flutter pub get` then `flutter run` (see [§2–3](#2-flutter-configuration)
  for env setup and [§3 Run](#3-run)).
- **Deploy migrations:** `supabase db push` (see [§1b](#b-run-the-migrations)).
- **Deploy Edge Function:** `supabase functions deploy extract-requests` and set
  `GEMINI_API_KEY` as a Supabase secret (see [§4](#4-whatsapp-import--gemini-extraction-edge-function)).
- **Before shipping a build, work through
  [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md)** — build commands,
  required env vars/secrets, the RLS + owner-isolation checks, the full
  import → billing → CSV test pass, and known limitations.

---

## What's wired up

- **Auth**: email/password sign up, sign in, sign out, email verification, and
  an auth gate with automatic session persistence (a returning user skips the
  login screen).
- **Owner profile**: created/loaded on first sign in from `owner_profiles`,
  editable in **Settings** (owner/mess name, phone, base counts, retention).
- **Import → extract**: paste / `.txt` / `.zip` WhatsApp export → `extract-requests`
  Edge Function (Gemini server-side, rule-based fallback) → saved as **pending**.
- **Requests**: filter (Pending / Approved / Rejected / All), search,
  approve / reject / edit / delete, batch approve.
- **Student matching & aliases**: imports and ledger entries resolve names
  through `students` + `student_aliases`, so short names ("Amit") link to the
  full student ("Amit Sharma") instead of duplicating. Link a request to an
  existing student (**Requests → ⋮ → Link student…**) to teach the alias;
  merge accidental duplicates in **Settings → Students → Merge**.
- **Semi-automatic ledger**: approving a **payment** or **dues** request
  auto-creates a single linked ledger entry (amount parsed conservatively from
  the message; a note when no amount is found). Re-approving never duplicates
  it, and normal meal requests never create ledger entries.
- **Home dashboard**: greeting, today's final lunch & dinner counts, pending /
  approved-today / import tallies, quick actions, and a recent-activity feed.
- **Daily count**: per-date base counts ± approved requests ± manual
  adjustments, with a full breakdown and unclear-date review section.
- **Ledger**: student-wise payment / due / adjustment / note entries with
  search, type filter, summary totals, and add / edit / delete.
- **Customers, plans & billing**: full customer lifecycle (active/paused/
  inactive), subscription **meal plans**, per-customer **payments**, generated
  **monthly bills**, customer balances, and an **audit log** of key actions.
- **Import history**: each import run and its parsed messages are stored
  (`chat_imports` / `chat_messages`) and browsable from the Import tab.
- **Retention / cleanup**: a Settings button deletes old **import history**
  (imported chat text) older than the retention window — customers, requests,
  ledger, billing and the account are untouched.
- **Database schema + RLS**: owner profiles, students/customers, aliases, import
  history, meal requests, meal plans, daily adjustments, ledger, payments,
  monthly bills and audit logs — each fully isolated per owner via RLS policies.

> Only `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_EMAIL_REDIRECT_URL` live
> in the app's `.env`. The **Gemini key never reaches the client** — it is a
> Supabase Edge Function secret only.

---

## 1. Supabase setup

### a. Create the project
1. Go to <https://supabase.com> → **New project**.
2. Note the project's **Project URL** and **anon/public API key** from
   **Project Settings → API**. (Never use the `service_role` key in the app.)

### b. Run the migrations
Open **SQL Editor** in the Supabase dashboard and run every file in
`supabase/migrations/` in order (`0001` … `0010`). Each migration is additive
and idempotent:

1. [`0001_init.sql`](supabase/migrations/0001_init.sql) — tables, indexes, triggers.
2. [`0002_rls.sql`](supabase/migrations/0002_rls.sql) — enables RLS and the per-owner policies.
3. [`0003_meal_requests_extraction.sql`](supabase/migrations/0003_meal_requests_extraction.sql) — reshapes `meal_requests` for the extraction vocabulary.
4. [`0004_dashboard_ledger.sql`](supabase/migrations/0004_dashboard_ledger.sql) — adds owner base lunch/dinner counts and reshapes `ledger_entries` (entry types + `student_name`).
5. [`0005_student_aliases_and_auto_ledger.sql`](supabase/migrations/0005_student_aliases_and_auto_ledger.sql) — adds the `student_aliases` table (+ its RLS) for name matching/merge, and a unique index so an approved payment/dues request creates at most one linked ledger entry.
6. [`0006_customers_plans_audit.sql`](supabase/migrations/0006_customers_plans_audit.sql) — customer lifecycle fields, meal plans (`meal_plans` / `customer_meal_plans`), `audit_logs`, and request-lifecycle fields on `meal_requests`.
7. [`0007_rls_plans_audit.sql`](supabase/migrations/0007_rls_plans_audit.sql) — RLS + per-owner policies for the meal-plan, customer-meal-plan and audit-log tables added in 0006.
8. [`0008_chat_imports_history.sql`](supabase/migrations/0008_chat_imports_history.sql) — import history (`chat_imports`, `chat_messages`), duplicate tracking (`request_duplicates`) and import-linkage columns on `meal_requests` (+ RLS).
9. [`0009_billing_foundation.sql`](supabase/migrations/0009_billing_foundation.sql) — `payments` and `monthly_bills` tables (+ RLS, indexes, and the `(owner_id, student_id, bill_month, bill_year)` unique key billing upserts on), plus billing entry types on `ledger_entries`.
10. [`0010_meal_cutoff_settings.sql`](supabase/migrations/0010_meal_cutoff_settings.sql) — owner meal times + a request-cutoff window on `owner_profiles`, plus the fields the Edge Function uses to flag late requests.

Prefer the CLI? With the [Supabase CLI](https://supabase.com/docs/guides/cli)
linked to your project:

```bash
supabase db push        # applies everything in supabase/migrations (0001 … 0010)
```

### c. Auth provider (email verification)
Under **Authentication → Providers → Email**, make sure **Email** is enabled.

**For production-like testing, turn _Confirm email_ ON** (Authentication →
Providers → Email → *Confirm email*). With it on:

- Sign up collects owner name, mess name, email, password (entered once) and
  stores the names in the user's auth metadata.
- Sign up returns **no session**, so the app shows the **Verify your email**
  screen — it does **not** enter the main app.
- The user clicks the link in their inbox, returns, and signs in normally.
- On first authenticated entry the owner profile is created **once** from the
  stored metadata, so the complete-profile screen is skipped.

If **Confirm email** is **OFF**, sign up returns a session immediately; the app
still works — it goes straight in and creates the profile from metadata on the
same launch. (No email step in that mode.)

> The main app is only ever reachable with a valid authenticated session, so an
> unverified account can never reach it regardless of this setting.

Signing up again with an email that already exists does **not** look like a
fresh success: Supabase returns an obfuscated user (empty identities) and the
app shows *"An account may already exist for this email. Please sign in instead,
or reset your password."* No duplicate profile is created.

### d. URL Configuration (fixes the "verification link error")
Under **Authentication → URL Configuration**:

- **Site URL**: a valid HTTPS page, e.g. `https://kotamess-poc.vercel.app`
- **Additional Redirect URLs**: add the **exact** value you set for
  `SUPABASE_EMAIL_REDIRECT_URL` (e.g. `https://kotamess-poc.vercel.app`).

The app passes this URL as `emailRedirectTo` on sign up / resend and as
`redirectTo` on password reset. **If the Site URL / Redirect URLs do not match,
the email link opens in the browser and shows an error** (e.g. "requested path
is invalid" / "redirect_to not allowed").

Target flow: user signs up → gets the email → opens the link **in a browser** →
Supabase verifies and lands on that harmless HTTPS page → user returns to the
app and signs in. (No Android deep link is wired up yet — that can come later.)

---

## 2. Flutter configuration

Copy the example env file and fill in the two values from step 1a:

```bash
cp .env.example .env
```

```dotenv
SUPABASE_URL=https://YOUR-PROJECT.supabase.co
SUPABASE_ANON_KEY=YOUR-PUBLIC-ANON-KEY
# Must match an entry in Supabase Auth -> URL Configuration (see step 1d).
SUPABASE_EMAIL_REDIRECT_URL=https://kotamess-poc.vercel.app
```

**`.env` is for local development only.** It is git-ignored, never committed,
and **not bundled as a build asset** — the app loads it best-effort at startup
and simply falls back to `--dart-define` values when it is absent, so a clean
build with no `.env` never fails. If `SUPABASE_URL`/`SUPABASE_ANON_KEY` resolve
to nothing the app shows a "Backend not configured" screen instead of crashing.
`SUPABASE_EMAIL_REDIRECT_URL` is optional — if blank, Supabase falls back to the
project Site URL.

> **Release / CI builds should use `--dart-define`** instead of an `.env`:
> `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
> --dart-define=SUPABASE_EMAIL_REDIRECT_URL=...`.

---

## 3. Run

```bash
flutter clean
flutter pub get
flutter devices                   # list connected devices + their ids
flutter run -d <device-id>        # run on a specific device, or:
flutter run                       # pick any connected device
```

Build a release APK:

```bash
flutter build apk --release
```

Final APK path:

```
build/app/outputs/flutter-apk/app-release.apk
```

> Android notes: `compileSdk = 36`, Java/Kotlin 17. `file_picker` is pinned to
> `10.3.8` and `archive` is used for `.zip` import — do not bump these unless a
> build break forces it.

### Source hygiene (what is intentionally NOT committed)

The repository ships only source. Local, generated and secret files are
git-ignored and are recreated by the tooling, so a fresh clone is clean:

- **`.env` is intentionally not committed/shared.** Create it from the example:
  ```bash
  cp .env.example .env
  ```
  and fill in `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
  `SUPABASE_EMAIL_REDIRECT_URL` (see step 2).
- The **Gemini API key must stay only in Supabase secrets**, never in the
  Flutter `.env`.
- These are regenerated automatically and are git-ignored — do not commit them:
  `android/local.properties`, `ios/Flutter/Generated.xcconfig`,
  `ios/Flutter/flutter_export_environment.sh`, `.flutter-plugins-dependencies`,
  `build/`, `.dart_tool/`, `.gradle/`, `android/.gradle/`, `android/.kotlin/`,
  `android/app/bin/`, `supabase/.temp/`, and any `*.apk` / `*.aab`. Running
  `flutter pub get` (and an Android build) recreates the ones the build needs.

### Release / demo build status

The current demo APK is built in **release mode but signed with the default
debug key** (`flutter build apk --release` with no custom signing config). That
is fine for **demo / internal testing**, but a proper Play Store production
release later still needs:

- a **custom package name** (currently `com.example.kotamess_owner`),
- **release keystore signing**,
- **app icon / name polish**, and
- a **custom SMTP** provider for reliable auth emails.

> These are intentionally out of scope right now — the package name and signing
> are unchanged so the Android build keeps working as-is.

---

## Manual values you must provide

| Value | Where to get it | Where it goes |
|-------|-----------------|---------------|
| `SUPABASE_URL` | Supabase → Project Settings → API → Project URL | `.env` |
| `SUPABASE_ANON_KEY` | Supabase → Project Settings → API → anon/public key | `.env` |
| `SUPABASE_EMAIL_REDIRECT_URL` | An HTTPS page you control, e.g. `https://kotamess-poc.vercel.app` | `.env` |
| Email auth enabled + Confirm email ON | Supabase → Authentication → Providers → Email | dashboard toggle |
| Site URL + Additional Redirect URLs | Supabase → Authentication → URL Configuration (must match the redirect URL) | dashboard |
| Migrations applied | run `0001` … `0010` in order | SQL editor / `supabase db push` |
| `GEMINI_API_KEY` (+ optional `GEMINI_MODEL`) | Google AI Studio | **Supabase secret only** — never in `.env` |

> Flutter `.env` holds **only** `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
> `SUPABASE_EMAIL_REDIRECT_URL`. The Gemini key lives **only** as a Supabase
> Edge Function secret and is never shipped in the app.

---

## 4. WhatsApp import → Gemini extraction (Edge Function)

The owner pastes or imports a WhatsApp chat; the app sends the **plain text** to
a Supabase Edge Function, which calls **Gemini server-side** and returns
structured meal requests. Raw `.zip`/media are never sent anywhere, and the
Gemini key never reaches the client.

### a. Apply the new migration
Run [`supabase/migrations/0003_meal_requests_extraction.sql`](supabase/migrations/0003_meal_requests_extraction.sql)
(after `0001`/`0002`). It reshapes `meal_requests` to:
`id, owner_id, student_id, student_name, original_message, request_type,
meal_type, request_date, date_label, status, confidence, reason, source,
created_at, updated_at` and reinstalls the value CHECK constraints. RLS is
unchanged.

### b. Deploy the function
The function lives at
[`supabase/functions/extract-requests/index.ts`](supabase/functions/extract-requests/index.ts).

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase functions deploy extract-requests
```

### c. Set the Gemini secret (server-side only)
```bash
supabase secrets set GEMINI_API_KEY=your_google_ai_studio_key
# optional — the function defaults to gemini-2.5-flash if this is unset
supabase secrets set GEMINI_MODEL=gemini-2.5-flash
```
`SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected into functions automatically.
The **Gemini API key lives only as a Supabase secret** — it is never placed in
the Flutter `.env`, never logged, and never returned to the client.

### d. How extraction behaves
- Requires a valid Supabase user JWT (the app sends it automatically).
- **Gemini available** → returns structured requests.
- **Gemini key missing / Gemini error / bad JSON / network failure** → the
  function uses a built-in **rule-based fallback parser**, still returns valid
  JSON, and adds a warning like *"Used fallback parser"* (shown in the app).
- Never crashes on bad input; returns user-friendly JSON.

### e. Test from the app
1. Sign in, open the **Import** tab.
2. Tap **Insert sample** (or **Choose .txt or .zip** / paste a chat), then
   **Import & extract**.
3. The server parses the chat, extracts requests and **saves them as pending**
   `meal_requests`; the app shows an import summary. If the orange banner shows,
   the fallback parser was used (set/redeploy the Gemini secret to use Gemini).
4. Tap **Review _N_ request(s)** → you're taken to the **Requests** tab to
   approve / reject them.

---

## Project layout (backend + auth + extraction)

```
lib/
  supabase/supabase_config.dart        # reads .env / --dart-define
  auth/
    auth_service.dart                  # sign up / in / out + session stream
    auth_gate.dart                     # routes: auth -> profile -> app
    auth_scaffold.dart                 # shared auth screen shell
    sign_in_screen.dart
    sign_up_screen.dart                # one-time owner/mess/email/password form
    verify_email_screen.dart           # "verify your email" + resend
  profile/
    owner_profile.dart                 # model for owner_profiles (counts, times, cutoff)
    owner_profile_service.dart         # load + idempotent upsert + metadata bootstrap
    complete_profile_screen.dart       # rare fallback when metadata is missing
  models/
    meal_request.dart                  # meal_requests row + label vocab
    imported_message.dart              # legacy imported_messages row
    chat_import.dart / chat_message.dart  # import-history rows (0008)
    extraction_result.dart             # Edge Function response models
    student.dart                       # students == customers (lifecycle fields)
    meal_plan.dart                     # meal_plans + customer_meal_plans
    payment.dart                       # payments row + CustomerBalance
    monthly_bill.dart                  # monthly_bills row + the bill formula
    audit_log.dart                     # audit_logs row
    daily_adjustment.dart / daily_summary.dart  # per-date counts + counting rules
    kitchen_summary.dart               # expected counts from active plans
    ledger_entry.dart                  # ledger_entries row + entry vocab
    dashboard.dart                     # dashboard summary + activity feed
  services/
    whatsapp_import.dart               # pick + read .txt / unzip .zip chat
    extraction_service.dart            # calls extract-requests Edge Function (server saves)
    database_service.dart              # requests / customers / plans / billing / cleanup
    money_utils.dart / name_utils.dart # amount parsing + name normalization
  screens/
    home_screen.dart                   # dashboard: counts, tallies, quick actions, activity
    chat_import_screen.dart            # paste/.txt/.zip -> import & extract (server saves pending)
    import_history_screen.dart / import_detail_screen.dart  # past imports + their requests
    meal_requests_screen.dart          # filter/search/approve/reject/edit/delete
    customers_screen.dart / customer_detail_screen.dart / customer_ledger_screen.dart
    meal_plans_screen.dart             # create/assign subscription plans
    monthly_bills_screen.dart          # generate + view monthly bills
    daily_screen.dart                  # per-date count, breakdown, manual adjustments
    ledger_screen.dart                 # customer-wise entries + totals + CRUD
    settings_screen.dart               # profile, base counts, cutoff, retention cleanup, logout
  widgets/
    confidence_badge.dart
    common.dart                        # shared cards / empty / error states
  main.dart                            # Supabase.initialize + AuthGate + shell
supabase/migrations/
  0001_init.sql                        # tables, indexes, updated_at trigger
  0002_rls.sql                         # Row Level Security policies
  0003_meal_requests_extraction.sql    # reshape meal_requests for extraction
  0004_dashboard_ledger.sql            # owner base counts + ledger reshape
  0005_student_aliases_and_auto_ledger.sql  # aliases + at-most-one auto ledger entry
  0006_customers_plans_audit.sql       # customer lifecycle, meal plans, audit logs
  0007_rls_plans_audit.sql             # RLS for plans / customer plans / audit logs
  0008_chat_imports_history.sql        # import history, messages, duplicate tracking
  0009_billing_foundation.sql          # payments + monthly_bills (+ RLS, indexes)
  0010_meal_cutoff_settings.sql        # owner meal times + request-cutoff window
supabase/functions/
  extract-requests/index.ts            # Gemini extraction + rule-based fallback
.env.example                           # Supabase URL/anon/redirect (NO Gemini key)
```

---

## 5. Demo script

A clean 2-minute walkthrough:

1. **Login** with a verified owner account (or sign up + verify first).
2. **Home dashboard** — greeting, today's lunch/dinner counts, pending /
   approved / import tallies, quick actions, recent activity.
3. **Import** a WhatsApp chat: tap **Insert sample**, or **Choose .txt or .zip**
   and pick a real export.
4. **Import & extract** — the server calls Gemini and **saves the extracted
   items as pending requests** (orange banner means the rule-based fallback ran
   instead), then shows an import summary.
5. Tap **Review request(s)** to jump to the Requests tab.
6. **Review** pending requests; use the filters and search.
7. **Approve** a couple and **reject** one.
8. Open **Daily** → the approved cancellations/additions change the final lunch
   and dinner counts; use the prev/next/date picker to move dates.
9. **Add a manual adjustment** (e.g. +2 lunch, "walk-in guests") and watch the
   total update.
10. Open **Ledger** → **Add entry**: a payment and a due note; see the totals and
    per-student balances update.
11. Open **Settings** (gear, top-right) → adjust **base counts**, confirm the
    **retention** window, and try **Clean old import history**.

### Tip: set base counts first
The Daily/Home totals start from `Settings → Default daily counts`. Set a base
lunch/dinner (e.g. 25 / 25) before the demo so approvals visibly add/subtract.

**These default counts are used every day until you change them** — they are
saved once in `owner_profiles` (Supabase) and persist across app restarts. You
do **not** set them per day. For a one-day change (guests, a holiday, etc.) use
**Daily → manual adjustments**, which is date-specific and never alters the
saved defaults.

---

## WhatsApp `.zip` exports

Android WhatsApp "Export chat" often produces a **`.zip`** (not a `.txt`),
especially "with media". The app handles both: pick a `.txt` directly, or pick
the `.zip` and it extracts the chat `.txt` inside (preferring `_chat.txt` /
`WhatsApp Chat with ….txt`), ignoring images/video/audio. If a zip has no chat
text file you get a friendly *"No chat text file found inside this WhatsApp
export."* Only the extracted plain text is sent to the backend.
