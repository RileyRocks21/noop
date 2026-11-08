# Nutrition tab (Google Sheets intake vs burn)

The **Nutrition** tab reads your "Nutrition & Macro Tracker Logs" Google Sheet and lines it up
against the day's burn (profile BMR + strap/Apple-Health active energy).

## Sheet schema

| Date | Meal Name | Calories | Protein (g) | Carbs (g) | Fat (g) | Notes |
|------|-----------|----------|-------------|-----------|---------|-------|

Dates are read as `YYYY-MM-DD` text, common locale date formats, or Sheets serial numbers.

## One-time Google setup

1. **Enable the Sheets API** — open
   <https://console.cloud.google.com/apis/library/sheets.googleapis.com?project=vmformarketdata>
   and click **Enable**.
2. **Share the sheet** — in Google Sheets, Share → add
   `appwhoop@vmformarketdata.iam.gserviceaccount.com` as **Viewer**.

## Getting the credential into the app

The service-account JSON is **never committed** (`StrandiOS/Resources/GoogleServiceAccount.json`
is gitignored). Two ways in:

- **CI (recommended):** repo Settings → Secrets and variables → Actions →
  `GOOGLE_SERVICE_ACCOUNT_JSON` = the full JSON file contents. The
  *Nutrition iOS build (fork)* workflow injects it into the bundle at build time.
- **On device:** drop a file named exactly `GoogleServiceAccount.json` into the app's
  Documents folder via the Files app (the app exposes Documents). It overrides the bundled copy.

## Build the IPA

Actions → **Nutrition iOS build (fork)** → Run workflow. The unsigned
`NOOP-nutrition-ios-unsigned-v*.ipa` lands as a workflow artifact; sideload with
AltStore / Sideloadly (they re-sign with your Apple ID).

## Editable in the app

- Nutrition tab → gear: weekday/weekend calorie targets (defaults 2,350 / 3,050 kcal),
  protein floor (200 g), deficit goal (350 kcal), spreadsheet ID.
- More → Settings → Profile: sex, date of birth, height, weight (the BMR inputs).

## Files

- `StrandiOS/Nutrition/NutritionModels.swift` — models + the three spec functions
  (`entries(forDate:)` / `balance(forDate:)` / `weeklySummary(...)`) + Mifflin–St Jeor.
- `StrandiOS/Nutrition/GoogleSheetsService.swift` — service-account JWT (RS256 via Security
  framework) → OAuth token → Sheets v4 values. No third-party dependencies.
- `StrandiOS/Nutrition/NutritionStore.swift` — fetch, parse, on-disk cache.
- `StrandiOS/Nutrition/NutritionView.swift` — the tab (day nav, balance, macros, 7-day trend,
  weekly summary, meal list).
- `StrandiOS/Nutrition/NutritionSettingsView.swift` — the settings sheet.
- `.github/workflows/nutrition-ipa.yml` — the unsigned IPA build.
