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
    public var needsUnknownPrice: Bool { paid && price == nil }

    public struct Price: Sendable {
        public let amount: Double
        public let currency: String
        public let per: String
        public let source: String
        public let asOf: String

        var json: [String: Any] {
            ["amount": amount, "currency": currency, "per": per, "source": source, "asOf": asOf]
        }
    }

    public var price: Price? {
        guard self == .bergetPianissimo else { return nil }
        return Price(amount: 0.0035, currency: "EUR", per: "audio minute",
                     source: "https://berget.ai/en/models", asOf: "2026-11-21")
    }

    static var paidOptions: [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: allCases.filter(\.paid).map { choice in
            let price = choice.price
            return (choice.rawValue, ["priceKnown": price != nil, "price": price.map { $0.json as Any } ?? NSNull()])
        })
    }
}
