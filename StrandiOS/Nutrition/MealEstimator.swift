#if os(iOS)
import Foundation
import UIKit

// MARK: - AI meal estimator
//
// Turns a meal description or a food photo into a macro estimate. Cost-minimal by construction:
//   • text estimates → gemini-flash-lite (cheapest Gemini tier; free-tier eligible) or Claude Haiku
//   • photo estimates → gemini-flash or Claude Haiku, with the image downscaled to ≤1024px JPEG
//     so a photo costs well under a cent
//   • barcodes never touch the AI at all (Open Food Facts is free) — see BarcodeScannerView
// The key is the same Keychain-stored BYOK key the AI Coach uses (AIKeyStore), so a key entered in
// Coach settings just works here, and vice versa.

struct MealEstimate: Codable, Equatable {
    var name: String
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var notes: String

    enum CodingKeys: String, CodingKey {
        case name, calories, notes
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}

enum MealEstimateError: LocalizedError {
    case noKey
    case noReply
    case unparseable(String)
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No AI key set. Add one in Nutrition settings (a free Google AI Studio key works)."
        case .noReply:
            return "The AI returned nothing. Try again, or log the meal manually."
        case .unparseable(let raw):
            return "Couldn't read the AI's answer as nutrition data. Raw reply: \(raw)"
        case .provider(let msg):
            return msg
        }
    }
}

enum MealEstimator {

    /// The strict-JSON instruction shared by every request. Numbers only, no units, no markdown —
    /// anything extra breaks the parse and wastes a retry.
    static let prompt = """
        Estimate the nutrition for the meal described or shown. Reply with ONLY a JSON object, \
        no markdown and no commentary: {"name": "short title", "calories": number, \
        "protein_g": number, "carbs_g": number, "fat_g": number, "notes": "one short sentence on assumptions"}. \
        Assume typical restaurant/home portion sizes when none are given. All numbers are totals \
        for the whole meal described, in kcal and grams.
        """

    // MARK: Public

    static func estimateFromText(_ description: String) async throws -> MealEstimate {
        try await estimate(text: description, imageJPEG: nil)
    }

    static func estimateFromPhoto(_ image: UIImage, hint: String) async throws -> MealEstimate {
        guard let jpeg = Self.downscaledJPEG(image, maxDimension: 1024, quality: 0.75) else {
            throw MealEstimateError.provider("Couldn't prepare that photo.")
        }
        let text = hint.isEmpty ? "Estimate the nutrition for the food in this photo."
                                : "Estimate the nutrition for the food in this photo. Note: \(hint)"
        return try await estimate(text: text, imageJPEG: jpeg)
    }

    // MARK: Dispatch

    private static func estimate(text: String, imageJPEG: Data?) async throws -> MealEstimate {
        guard let key = AIKeyStore.read() else { throw MealEstimateError.noKey }
        let owner = AIKeyStore.ownerProvider.flatMap { AIProvider(rawValue: $0) } ?? .gemini
        switch owner {
        case .gemini:
            // flash-lite for text-only (cheapest), flash for photos (vision).
            let model = imageJPEG == nil ? "gemini-flash-lite-latest" : "gemini-flash-latest"
            return try await gemini(key: key, model: model, text: text, imageJPEG: imageJPEG)
        case .anthropic:
            return try await anthropic(key: key, model: "claude-haiku-4-5-20251001",
                                       text: text, imageJPEG: imageJPEG)
        case .openAI:
            return try await openAI(key: key, model: "gpt-4o-mini", text: text, imageJPEG: imageJPEG)
        case .custom:
            throw MealEstimateError.provider("The Custom provider isn't wired for meal estimates — pick Gemini or Anthropic in Nutrition settings.")
        }
    }

    // MARK: Gemini (generateContent)

    private static func gemini(key: String, model: String, text: String, imageJPEG: Data?) async throws -> MealEstimate {
        var parts: [[String: Any]] = [["text": prompt + "\n\n" + text]]
        if let imageJPEG {
            parts.append(["inline_data": ["mime_type": "image/jpeg",
                                          "data": imageJPEG.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "temperature": 0.2,
                "maxOutputTokens": 512,
            ],
        ]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 45

        let json = try await post(req)
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let replyParts = content["parts"] as? [[String: Any]],
              let reply = replyParts.compactMap({ $0["text"] as? String }).first,
              !reply.isEmpty else {
            throw MealEstimateError.noReply
        }
        return try parse(reply)
    }

    // MARK: Anthropic (messages)

    private static func anthropic(key: String, model: String, text: String, imageJPEG: Data?) async throws -> MealEstimate {
        var content: [[String: Any]] = []
        if let imageJPEG {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": "image/jpeg",
                                       "data": imageJPEG.base64EncodedString()]])
        }
        content.append(["type": "text", "text": text])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": prompt,
            "messages": [["role": "user", "content": content]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 45

        let json = try await post(req)
        guard let blocks = json["content"] as? [[String: Any]],
              let reply = blocks.compactMap({ $0["text"] as? String }).first,
              !reply.isEmpty else {
            throw MealEstimateError.noReply
        }
        return try parse(reply)
    }

    // MARK: OpenAI (chat completions) — supported for completeness; user pays per call.

    private static func openAI(key: String, model: String, text: String, imageJPEG: Data?) async throws -> MealEstimate {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let imageJPEG {
            content.append(["type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"]])
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": content],
            ],
        ]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 45

        let json = try await post(req)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let reply = message["content"] as? String, !reply.isEmpty else {
            throw MealEstimateError.noReply
        }
        return try parse(reply)
    }

    // MARK: Shared HTTP + parse

    private static func post(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MealEstimateError.noReply }
        guard (200..<300).contains(http.statusCode) else {
            let msg = providerErrorMessage(from: data)
            if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
                throw MealEstimateError.provider("The AI provider rejected the key (HTTP \(http.statusCode)). \(msg)")
            }
            if http.statusCode == 429 {
                throw MealEstimateError.provider("Rate limited by the provider — wait a moment and retry. \(msg)")
            }
            throw MealEstimateError.provider("Provider error HTTP \(http.statusCode). \(msg)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MealEstimateError.noReply
        }
        return json
    }

    /// Lenient JSON extraction: take the first { … last } span, so a stray code fence or sentence
    /// around the object doesn't waste the call.
    private static func parse(_ reply: String) throws -> MealEstimate {
        guard let open = reply.firstIndex(of: "{"),
              let close = reply.lastIndex(of: "}"), close >= open else {
            throw MealEstimateError.unparseable(reply)
        }
        let slice = String(reply[open...close])
        guard let data = slice.data(using: .utf8),
              var estimate = try? JSONDecoder().decode(MealEstimate.self, from: data) else {
            throw MealEstimateError.unparseable(reply)
        }
        // Clamp nonsense so a hallucinated negative never lands in the log.
        estimate.calories = max(0, estimate.calories)
        estimate.proteinG = max(0, estimate.proteinG)
        estimate.carbsG = max(0, estimate.carbsG)
        estimate.fatG = max(0, estimate.fatG)
        if estimate.name.trimmingCharacters(in: .whitespaces).isEmpty { estimate.name = "Meal" }
        return estimate
    }

    /// Downscale + recompress for upload. 1024px keeps labels/plates legible while the token cost
    /// stays at the low image tier for both providers.
    static func downscaledJPEG(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return rendered.jpegData(compressionQuality: quality)
    }
}
#endif
