import Foundation

/// Transcription choices shared by the API, Batch and the editor.
public enum TranscriptionChoice: String, CaseIterable, Sendable {
    case auto, apple, parakeet, whisper, pianissimo, openai
    case bergetPianissimo = "berget_pianissimo"

    public var provider: String? {
        switch self {
        case .openai: "OpenAI"
        case .bergetPianissimo: "Berget AI"
        default: nil
        }
    }

    public var paid: Bool { provider != nil }

    /// The languages (ISO 639-1) this engine transcribes, or nil for any the panel offers: the panel greys out the
    /// rest, so a choice that can't work is seen before Transcribe, not after.
    public var languages: Set<String>? {
        switch self {
        case .pianissimo: ["sv", "da"]
        case .bergetPianissimo: ["sv"]
        default: nil
        }
    }
    public var needsUnknownPrice: Bool { paid && price == nil }

    public struct Price: Sendable {
        public let amount: Double
        public let currency: String
        public let per: String
        public let source: String
        public let asOf: String
        /// The provider's own words for the rate, as read at `source` on `asOf` (SIBLINGS, "Okänt pris").
        public let quote: String

        var json: [String: Any] {
            ["amount": amount, "currency": currency, "per": per, "source": source, "asOf": asOf, "quote": quote]
        }
    }

    public var price: Price? {
        guard self == .bergetPianissimo else { return nil }
        // Berget's model list gives the rate per second; 5.833333e-05 × 60 = 0.0035 per audio minute.
        return Price(amount: 0.0035, currency: "EUR", per: "audio minute",
                     source: "https://api.berget.ai/v1/models", asOf: "2026-11-25",
                     quote: #"{"id": "klang/pianissimo", "pricing": {"currency": "EUR", "input": 5.833333e-05, "unit": "€ / second"}}"#)
    }

    static var paidOptions: [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: allCases.filter(\.paid).map { choice in
            let price = choice.price
            return (choice.rawValue, ["priceKnown": price != nil, "price": price.map { $0.json as Any } ?? NSNull()])
        })
    }
}
