#if os(iOS)
import SwiftUI
import AVFoundation
import Vision

// MARK: - Barcode scanning (on-device Vision) + Open Food Facts lookup (free, no key)
//
// Zero AI cost: the camera feed is scanned locally with VNDetectBarcodesRequest, and the code is
// looked up in Open Food Facts' open database. The result prefills the meal editor, editable
// before saving.

/// Camera view that emits the first barcode it sees. Wraps AVCaptureSession + Vision.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var fired = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "noop.barcode"))
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            self.previewLayer = preview

            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        private var previewLayer: AVCaptureVideoPreviewLayer?

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard !fired, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let request = VNDetectBarcodesRequest { [weak self] req, _ in
                guard let self, !self.fired else { return }
                guard let code = (req.results as? [VNBarcodeObservation])?
                    .first(where: { $0.symbology == .ean13 || $0.symbology == .ean8
                        || $0.symbology == .upce || $0.symbology == .code128 || $0.symbology == .qr })?
                    .payloadStringValue else { return }
                self.fired = true
                DispatchQueue.main.async { self.onCode?(code) }
            }
            try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        }
    }
}

// MARK: - Open Food Facts

enum OpenFoodFacts {
    struct Product {
        let name: String
        let calories: Double
        let proteinG: Double
        let carbsG: Double
        let fatG: Double
        let basis: String     // e.g. "per 100 g" or "per serving (30 g)"
    }

    /// Look up a barcode. Returns nil when the product isn't in the database.
    static func lookup(_ barcode: String) async throws -> Product? {
        let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json")!
        var req = URLRequest(url: url)
        req.setValue("NOOP nutrition logger (personal use)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? Int) == 1,
              let product = json["product"] as? [String: Any] else { return nil }

        let n = product["nutriments"] as? [String: Any] ?? [:]
        func num(_ key: String) -> Double? {
            (n[key] as? NSNumber)?.doubleValue
        }
        let name = (product["product_name"] as? String)?.trimmingCharacters(in: .whitespaces)
        let serving = product["serving_size"] as? String

        // Prefer per-serving figures when the product declares a serving; else per 100 g.
        if num("energy-kcal_serving") != nil {
            return Product(name: (name?.isEmpty == false ? name! : "Scanned product"),
                           calories: num("energy-kcal_serving") ?? 0,
                           proteinG: num("proteins_serving") ?? 0,
                           carbsG: num("carbohydrates_serving") ?? 0,
                           fatG: num("fat_serving") ?? 0,
                           basis: "per serving (\(serving ?? "1 serving"))")
        }
        return Product(name: (name?.isEmpty == false ? name! : "Scanned product"),
                       calories: num("energy-kcal_100g") ?? 0,
                       proteinG: num("proteins_100g") ?? 0,
                       carbsG: num("carbohydrates_100g") ?? 0,
                       fatG: num("fat_100g") ?? 0,
                       basis: "per 100 g")
    }
}
#endif
