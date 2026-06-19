# Production Checklist — KotaMess Owner

Pre-release checklist for the KotaMess Owner Flutter + Supabase app. Work top to
bottom; every box should be ticked before shipping a build to a real owner.

> Naming note: in the database `students` = customers and `meal_requests` =
> extracted requests.

---

## 1. Build & deploy commands

### Flutter

```bash
flutter clean
flutter pub get
flutter analyze                 # must be clean (no errors)
flutter test                    # if/when tests exist

flutter run                     # run on a connected device
flutter build apk --release     # release APK
```

Release APK output:

```
build/app/outputs/flutter-apk/app-release.apk
```

### Supabase migrations

With the [Supabase CLI](https://supabase.com/docs/guides/cli) linked to the
project (`supabase link --project-ref <ref>`):

```bash
supabase db push                # applies everything in supabase/migrations (0001 … 0010)
```

Or run the files in `supabase/migrations/` in order (`0001` … `0010`) in the SQL
editor. Every migration is additive and idempotent, so re-running is safe.

### Supabase Edge Function

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase functions deploy extract-requests
```

---

## 2. Environment variables / secrets

### Flutter app (`.env` or `--dart-define`) — client-safe values only

| Variable | Required | Notes |
|----------|----------|-------|
| `SUPABASE_URL` | ✅ | Supabase → Project Settings → API → Project URL |
| `SUPABASE_ANON_KEY` | ✅ | Supabase anon / public (publishable) key. **Never** the `service_role` key |
| `SUPABASE_EMAIL_REDIRECT_URL` | optional | HTTPS page for auth links; falls back to project Site URL if blank |

`.env` is for **local development only** — it is git-ignored, never committed,
and **not bundled as a build asset** (the app loads it best-effort and falls
back to `--dart-define` when it is absent, so a clean build with no `.env` still
works). **Release / CI builds should inject these with `--dart-define`:**
`--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`.

### Supabase Edge Function secrets — server-side only

| Secret | Required | Notes |
|--------|----------|-------|
| `GEMINI_API_KEY` | ✅ | Google AI Studio key. **Server-side only — never in the app `.env`** |
| `GEMINI_MODEL` | optional | Defaults to `gemini-2.5-flash` if unset |

```bash
supabase secrets set GEMINI_API_KEY=your_google_ai_studio_key
supabase secrets set GEMINI_MODEL=gemini-2.5-flash   # optional
```

`SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected into Edge Functions
automatically.

- [ ] `.env` is **not** committed (it is git-ignored) and is not a bundled asset
- [ ] `service_role` key appears nowhere in the client app or the Edge Function
- [ ] `GEMINI_API_KEY` exists only as a Supabase secret, never in `.env`
- [ ] APK/AAB outputs, keystores (`*.jks` / `*.keystore` / `key.properties`),
      `build/`, `.dart_tool/`, `.gradle/` and `supabase/.temp/` are git-ignored
      (never committed)

---

## 3. RLS (Row Level Security) checklist

- [ ] RLS is **enabled** on every owner-scoped table: `owner_profiles`,
      `students`, `student_aliases`, `imported_messages`, `chat_imports`,
      `chat_messages`, `request_duplicates`, `meal_requests`, `meal_plans`,
      `customer_meal_plans`, `daily_adjustments`, `ledger_entries`, `payments`,
      `monthly_bills` and `audit_logs`.
- [ ] Each table has policies restricting `select / insert / update / delete`
      to `auth.uid() = owner_id`.
- [ ] No table is left with RLS off / a permissive `using (true)` policy.
- [ ] Edge Function requires a valid Supabase user JWT (rejects anonymous calls).

---

## 4. Functional test passes

### Owner isolation
- [ ] Sign in as Owner A, create a customer + a request + a ledger entry.
- [ ] Sign in as Owner B; confirm **none** of Owner A's data is visible.
- [ ] Owner B cannot read/update/delete Owner A's rows by id (RLS blocks it).

### Import / extraction
- [ ] Import a `.txt` and a `.zip` WhatsApp export.
- [ ] Run extraction; Gemini path returns structured requests.
- [ ] Force the fallback (no/invalid Gemini key) → orange "fallback parser"
      banner shows, app still returns valid requests, no crash on bad input.
- [ ] Saved items appear as **pending** requests.

### Customer / meal plan
- [ ] Create, edit and delete a customer (student).
- [ ] Create a meal plan and assign it to a customer.
- [ ] Merge two duplicate customers; requests + ledger move to the kept one and
      the removed name becomes an alias.

### Request lifecycle
- [ ] Approve, reject, edit and delete requests; batch approve works.
- [ ] Filters (Pending / Approved / Rejected / All) and search work.
- [ ] Link a request to an existing customer to teach the alias.

### Billing / payment / monthly bill
- [ ] Generate a monthly bill; amounts match expected meal counts.
- [ ] Record a payment; balance/dues update correctly.
- [ ] Re-approving a payment/dues request never duplicates the ledger entry.

### CSV / export
- [ ] CSV export produces a valid file with the expected columns.
- [ ] Exported figures match what is shown on screen.

### Privacy & Data (Settings)
- [ ] "Privacy & Data" card is visible and readable.
- [ ] "Request account deletion" shows the contact-support dialog (it does
      **not** delete anything automatically).

---

## 5. APK build checklist

- [ ] `flutter analyze` is clean.
- [ ] `flutter build apk --release` succeeds.
- [ ] App launches and reaches the dashboard on a real device.
- [ ] "Backend not configured" screen shows when env vars are missing (instead
      of crashing).
- [ ] App icon and app name reviewed.

---

## 6. Known limitations

- **Account deletion is not automated.** "Request account deletion" only shows a
  contact-support dialog; data is removed manually by an admin.
- **Release signing:** demo APK is built `--release` but signed with the default
  **debug key**. A Play Store release still needs a custom package name (currently
  `com.example.kotamess_owner`), a release keystore, and icon/name polish.
- **Auth email:** uses Supabase's default SMTP; a custom SMTP provider is needed
  for reliable production auth emails.
- **No Android deep link** for email verification yet — the link opens an HTTPS
  page and the user returns to the app to sign in.
- **`anonKey` naming:** the client uses the Supabase anon/publishable key; see
  the README/notes if the SDK later renames the `anonKey` parameter.
