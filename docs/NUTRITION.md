# Nutrition tab (in-app AI logging, intake vs burn)

The **Nutrition** tab logs meals directly in the app and lines intake up against the day's burn
(profile BMR + strap/Apple-Health active energy). No spreadsheet in the loop.

## Logging a meal (tap + on the Nutrition tab)

| Path | Cost | Notes |
|------|------|-------|
| **Describe** ("chicken burrito bowl, large") | fractions of a cent | gemini-flash-lite / Claude Haiku |
| **Photo** (camera or library, optional hint) | under a cent | image downscaled to 1024px to stay cheap |
| **Barcode** | **free** | on-device Vision scan → Open Food Facts lookup, no AI |
| **Manual** | free | type the numbers |
| **Recent meals** | free | one-tap re-log of anything you've logged before |

Every AI/barcode result lands in an **editable review card** — nothing is saved until you confirm.
Meals are stored on-device in `Documents/nutrition_log.json` (visible/backable-up via Files).

## AI key (BYOK, shared with the AI Coach)

Nutrition tab → gear → **AI estimation**: pick the provider and paste a key. It's the same
Keychain slot the AI Coach uses, so a key saved there works here.

- **Cheapest:** a free Google AI Studio key (https://aistudio.google.com) — text estimates run on
  `gemini-flash-lite`, photos on `gemini-flash`.
- Anthropic estimates run on `claude-haiku-4-5`. OpenAI on `gpt-4o-mini`.

## Google Sheet history (one-time import)

Nutrition settings → "Import history from sheet now" pulls your old "Nutrition & Macro Tracker
Logs" rows into the local log (deduped). Needs the Sheets API enabled, the sheet shared with the
service-account email, and `GoogleServiceAccount.json` in the bundle (CI secret
`GOOGLE_SERVICE_ACCOUNT_JSON`) or the app's Documents folder.

## Build the IPA

Actions → **Nutrition iOS build (fork)** → Run workflow. The unsigned
`NOOP-nutrition-ios-unsigned-v*.ipa` lands as a workflow artifact; sideload with
AltStore / Sideloadly (they re-sign with your Apple ID).

## Editable in the app

- Nutrition tab → gear: weekday/weekend calorie targets (defaults 2,350 / 3,050 kcal),
  protein floor (200 g), deficit goal (350 kcal), AI provider + key, sheet import.
- More → Settings → Profile: sex, date of birth, height, weight (the BMR inputs).

## Files

- `StrandiOS/Nutrition/NutritionModels.swift` — models + balance/weekly-summary math + Mifflin–St Jeor.
- `StrandiOS/Nutrition/NutritionStore.swift` — local meal log (CRUD, JSON persistence) + sheet import.
- `StrandiOS/Nutrition/MealEstimator.swift` — Gemini / Anthropic / OpenAI text + photo estimates (strict JSON).
- `StrandiOS/Nutrition/BarcodeScannerView.swift` — Vision barcode capture + Open Food Facts lookup.
- `StrandiOS/Nutrition/LogMealView.swift` — the Log Meal sheet (four capture paths + review card).
- `StrandiOS/Nutrition/NutritionView.swift` — the tab (day nav, balance, macros, 7-day trend,
  weekly summary, meal list).
- `StrandiOS/Nutrition/NutritionSettingsView.swift` — the settings sheet.
- `StrandiOS/Nutrition/GoogleSheetsService.swift` — service-account Sheets reader (import only).
- `.github/workflows/nutrition-ipa.yml` — the unsigned IPA build.
