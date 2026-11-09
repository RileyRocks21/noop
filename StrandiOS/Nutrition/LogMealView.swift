#if os(iOS)
import SwiftUI
import PhotosUI
import StrandDesign

// MARK: - Log Meal sheet
//
// One sheet, four capture paths: describe in text (AI), photograph (AI), scan a barcode (free),
// or type numbers by hand. Every AI/barcode result lands in an editable draft — nothing is saved
// until the wearer confirms. Recent meals re-log with one tap and no AI call.

struct LogMealView: View {
    let dayKey: String
    @ObservedObject var store: NutritionStore
    @Environment(\.dismiss) private var dismiss

    @State private var describeText = ""
    @State private var hint = ""
    @State private var draft = MealEstimate(name: "", calories: 0, proteinG: 0, carbsG: 0, fatG: 0, notes: "")
    @State private var hasDraft = false
    @State private var isWorking = false
    @State private var workingLabel = ""
    @State private var errorText: String?

    @State private var showCamera = false
    @State private var showScanner = false
    @State private var photoItem: PhotosPickerItem?
    /// Provenance tag for the log entry; set by whichever capture path filled the draft.
    @State private var draftSource = "manual"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // AI capture
                    VStack(alignment: .leading, spacing: 10) {
                        Text("DESCRIBE OR PHOTOGRAPH").strandOverline()
                        TextField("e.g. Domino's chicken alfredo pasta, no bread bowl",
                                  text: $describeText, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 10) {
                            Button { Task { await runEstimate(text: describeText, photo: nil) } } label: {
                                Label("Estimate", systemImage: "sparkles")
                            }
                            .disabled(describeText.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)

                            Menu {
                                Button { showCamera = true } label: { Label("Take photo", systemImage: "camera") }
                                PhotosPicker(selection: $photoItem, matching: .images) {
                                    Label("Choose photo", systemImage: "photo")
                                }
                            } label: {
                                Label("Photo", systemImage: "camera.fill")
                            }
                            .disabled(isWorking)

                            Button { showScanner = true } label: {
                                Label("Barcode", systemImage: "barcode.viewfinder")
                            }
                            .disabled(isWorking)
                        }
                        .buttonStyle(.bordered)
                        .tint(StrandPalette.accent)

                        TextField("Optional note for the photo (e.g. \"large portion\", \"no dressing\")",
                                  text: $hint)
                            .textFieldStyle(.roundedBorder)
                            .font(StrandFont.footnote)
                    }

                    if isWorking {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(workingLabel).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }

                    if let errorText {
                        Text(errorText)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.metricRose)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Editable result — the confirm step.
                    if hasDraft {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("REVIEW & SAVE").strandOverline()
                            TextField("Meal name", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 10) {
                                draftField("kcal", $draft.calories)
                                draftField("Protein g", $draft.proteinG)
                            }
                            HStack(spacing: 10) {
                                draftField("Carbs g", $draft.carbsG)
                                draftField("Fat g", $draft.fatG)
                            }
                            TextField("Notes (optional)", text: $draft.notes)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                store.add(LoggedMeal(date: dayKey, name: draft.name,
                                                     calories: draft.calories, proteinG: draft.proteinG,
                                                     carbsG: draft.carbsG, fatG: draft.fatG,
                                                     notes: draft.notes, source: draftSource))
                                dismiss()
                            } label: {
                                Text("Log meal")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(StrandPalette.accent)
                            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    // Free re-log of past meals.
                    if !store.recentMeals.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RECENT — TAP TO RE-LOG").strandOverline()
                            ForEach(store.recentMeals) { meal in
                                Button {
                                    store.add(LoggedMeal(date: dayKey, name: meal.name,
                                                         calories: meal.calories, proteinG: meal.proteinG,
                                                         carbsG: meal.carbsG, fatG: meal.fatG,
                                                         notes: meal.notes, source: meal.source))
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(meal.name)
                                            .font(StrandFont.subhead)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(Int(meal.calories.rounded())) kcal · P\(Int(meal.proteinG.rounded()))")
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Log meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            // Manual entry — zero taps hidden behind AI.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Manual") { draftSource = "manual"; hasDraft = true; errorText = nil }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    if let image {
                        Task { await runEstimate(text: hint, photo: image) }
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    BarcodeScannerView { code in
                        showScanner = false
                        Task { await lookupBarcode(code) }
                    }
                    .navigationTitle("Scan barcode")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { showScanner = false }
                        }
                    }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await runEstimate(text: hint, photo: image)
                    }
                    photoItem = nil
                }
            }
        }
    }

    private func draftField(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func runEstimate(text: String, photo: UIImage?) async {
        errorText = nil
        isWorking = true
        workingLabel = photo == nil ? "Estimating…" : "Reading photo…"
        defer { isWorking = false }
        do {
            let estimate: MealEstimate
            if let photo {
                estimate = try await MealEstimator.estimateFromPhoto(photo, hint: text)
                draftSource = "ai-photo"
            } else {
                estimate = try await MealEstimator.estimateFromText(text)
                draftSource = "ai-text"
            }
            draft = estimate
            hasDraft = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func lookupBarcode(_ code: String) async {
        errorText = nil
        isWorking = true
        workingLabel = "Looking up \(code)…"
        defer { isWorking = false }
        do {
            guard let product = try await OpenFoodFacts.lookup(code) else {
                errorText = "Barcode \(code) isn't in Open Food Facts. Describe it or photograph it instead."
                return
            }
            draft = MealEstimate(name: product.name, calories: product.calories,
                                 proteinG: product.proteinG, carbsG: product.carbsG,
                                 fatG: product.fatG, notes: "Barcode \(code) · \(product.basis)")
            draftSource = "barcode"
            hasDraft = true
        } catch {
            errorText = NutritionStore.describe(error)
        }
    }
}

// MARK: - Camera picker (UIImagePickerController — photos only, no microphone usage)

private struct CameraPicker: UIViewControllerRepresentable {
    /// nil = cancelled. The closure owns closing the cover (sets the binding false).
    let onDone: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}
#endif
