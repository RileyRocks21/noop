#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Nutrition settings sheet
//
// Targets, the AI key for meal estimation (the SAME Keychain slot the AI Coach uses — one key for
// the whole app), body-profile pointer, and the one-time Google Sheet import. Body profile
// (sex / age / height / weight — the BMR inputs) lives in the app's main Settings → Profile.

struct NutritionSettingsView: View {
    @AppStorage("noop.nutrition.weekdayKcal") private var weekdayKcal = 2350.0
    @AppStorage("noop.nutrition.weekendKcal") private var weekendKcal = 3050.0
    @AppStorage("noop.nutrition.proteinFloor") private var proteinFloor = 200.0
    @AppStorage("noop.nutrition.deficitGoal") private var deficitGoal = 350.0
    @AppStorage("noop.nutrition.spreadsheetID") private var spreadsheetID = GoogleSheetsService.defaultSpreadsheetID
    @AppStorage("noop.nutrition.provider") private var providerRaw = AIProvider.gemini.rawValue

    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var keyNote: String?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = NutritionStore.shared

    private var provider: AIProvider {
        AIProvider(rawValue: providerRaw) ?? .gemini
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    numberField("Weekday calorie target", value: $weekdayKcal, unit: "kcal")
                    numberField("Weekend calorie target", value: $weekendKcal, unit: "kcal")
                    numberField("Protein floor", value: $proteinFloor, unit: "g")
                    numberField("Average daily deficit goal", value: $deficitGoal, unit: "kcal")
                } header: {
                    Text("Targets")
                } footer: {
                    Text("Applied per day type (Sat/Sun = weekend) in the balance card and weekly summary.")
                }

                Section {
                    Picker("Provider", selection: $providerRaw) {
                        Text("Google Gemini (free tier)").tag(AIProvider.gemini.rawValue)
                        Text("Anthropic Claude").tag(AIProvider.anthropic.rawValue)
                        Text("OpenAI").tag(AIProvider.openAI.rawValue)
                    }
                    SecureField("API key", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if hasKey {
                        Label("Key saved in the Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                    Button("Save key") {
                        let ok = AIKeyStore.save(keyInput, owner: providerRaw)
                        hasKey = AIKeyStore.read() != nil
                        keyNote = ok ? "Saved." : "Keychain write failed."
                        keyInput = ""
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let keyNote {
                        Text(keyNote).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI estimation")
                } footer: {
                    Text("Cheapest setup: a free Google AI Studio key (aistudio.google.com) — text estimates run on Flash-Lite, photo estimates on Flash, both fractions of a cent. Barcodes never use the AI. This key slot is shared with the AI Coach, so a key saved there already works here.")
                }

                Section {
                    Text("Burn estimate = BMR (Mifflin–St Jeor, from your profile) + active energy from the strap / Apple Health. Edit sex, age, height and weight under More → Settings → Profile.")
                        .font(.footnote)
                } header: {
                    Text("Body profile")
                }

                Section {
                    TextField("Spreadsheet ID", text: $spreadsheetID)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await store.importFromSheet(spreadsheetID: spreadsheetID) }
                    } label: {
                        Label("Import history from sheet now", systemImage: "square.and.arrow.down")
                    }
                    .disabled(store.isImporting)
                } header: {
                    Text("Google Sheet (one-time import)")
                } footer: {
                    Text("Brings your existing log into the app once; new meals are logged in the app. Needs the Sheets API enabled, the sheet shared with the service-account email, and GoogleServiceAccount.json in the bundle (CI secret) or the app's Documents folder.")
                }
            }
            .navigationTitle("Nutrition settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                hasKey = AIKeyStore.read() != nil
                if let owner = AIKeyStore.ownerProvider { providerRaw = owner }
            }
        }
    }

    private func numberField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
#endif
