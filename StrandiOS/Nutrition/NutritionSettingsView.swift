#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Nutrition settings sheet
//
// Everything the tab needs that the user can edit: calorie/protein targets, the deficit goal,
// and the sheet connection. Body profile (sex / age / height / weight — the BMR inputs) already
// lives in the app's main Settings → Profile, so this sheet just points there.

struct NutritionSettingsView: View {
    @AppStorage("noop.nutrition.weekdayKcal") private var weekdayKcal = 2350.0
    @AppStorage("noop.nutrition.weekendKcal") private var weekendKcal = 3050.0
    @AppStorage("noop.nutrition.proteinFloor") private var proteinFloor = 200.0
    @AppStorage("noop.nutrition.deficitGoal") private var deficitGoal = 350.0
    @AppStorage("noop.nutrition.spreadsheetID") private var spreadsheetID = GoogleSheetsService.defaultSpreadsheetID

    @Environment(\.dismiss) private var dismiss

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
                    TextField("Spreadsheet ID", text: $spreadsheetID)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The ID from the sheet's URL (the long code between /d/ and /edit). Defaults to your tracker sheet.")
                }

                Section {
                    Text("Burn estimate = BMR (Mifflin–St Jeor, from your profile) + active energy from the strap / Apple Health. Edit sex, age, height and weight under More → Settings → Profile.")
                        .font(.footnote)
                } header: {
                    Text("Body profile")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Enable the Google Sheets API in Google Cloud Console (project vmformarketdata).", systemImage: "1.circle")
                        Label("Share the sheet with your service-account email (Viewer).", systemImage: "2.circle")
                        Label("Build with the GOOGLE_SERVICE_ACCOUNT_JSON secret, or drop GoogleServiceAccount.json into this app's Documents folder via Files.", systemImage: "3.circle")
                    }
                    .font(.footnote)
                } header: {
                    Text("Setup")
                }
            }
            .navigationTitle("Nutrition settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
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
