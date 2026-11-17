import Foundation

/// One value in a sentence: text (a name, an id, a whole number), or a number with fractions that the window
/// writes in the Mac's region (0,5 in Sweden) and the API as it always has (0.5). Anders, 2026-11-17: numbers
/// follow the region, in either language, also inside a sentence.
public enum SaidValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    case text(String)
    /// `decimals` nil: as few as it takes (up to six), as `Double.plain` writes it.
    case number(Double, decimals: Int?)
    public init(stringLiteral value: String) { self = .text(value) }
    public init(stringInterpolation: DefaultStringInterpolation) { self = .text(String(stringInterpolation: stringInterpolation)) }
    /// As the API says it: a point, fixed decimals or as few as it takes.
    public var english: String {
        switch self {
        case .text(let s): return s
        case .number(let v, let d?): return String(format: "%.\(d)f", v)
        case .number(let v, nil): return v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String((v * 1_000_000).rounded() / 1_000_000)
        }
    }
}

/// A message by its key in the app's string catalogue, with its values: what lets the window say an
/// error in the window's language while `errorDescription` (and so the agent API) keeps its English words.
/// The catalogue's entry has `%1$@`, `%2$@` where the values go; a number among them is written by the window
/// in the Mac's region. `scripts/check-strings.py` holds each key's English to the words of `errorDescription`.
public struct KeyedMessage: Sendable, Equatable {
    public var key: String
    public var args: [SaidValue]
    /// Sentences that go in this one's last places, after `args`, each said in the window's language too
    /// ("The file can't be read as a timeline: %@" with "it isn't JSON." inside).
    public var inner: [KeyedMessage]
    public init(_ key: String, _ args: [String] = [], inner: [KeyedMessage] = []) {
        self.key = key
        self.args = args.map(SaidValue.text)
        self.inner = inner
    }
    public init(_ key: String, values: [SaidValue], inner: [KeyedMessage] = []) {
        self.key = key
        self.args = values
        self.inner = inner
    }
}

/// An error that can be said by key. nil for a case whose words are made where it is thrown (those stay
/// as they were written until each has an entry of its own).
public protocol KeyedFailure: Error {
    var keyed: KeyedMessage? { get }
}

/// A sentence written where it is said, in English with `%@` (or `%1$@`, `%2$@`…) where its values go, and
/// the key the window says it by: `text` is the English (for the agent API, logs and tests), `keyed` the
/// key and its values (for the window, in its language). `scripts/check-strings.py` holds every
/// Said(key, English, …) in the packages to the catalogue's English for that key, so the two say one thing.
public struct Said: Sendable, Equatable, CustomStringConvertible {
    public let text: String
    public let keyed: KeyedMessage
    public init(_ key: String, _ english: String, _ args: String...) { self.init(key, english, args) }
    public init(_ key: String, _ english: String, _ args: [String]) {
        keyed = KeyedMessage(key, args)
        text = Self.fill(english, args)
    }
    /// With numbers among the values (`Said.n`): the window writes them in the Mac's region.
    public init(_ key: String, _ english: String, values: [SaidValue]) {
        keyed = KeyedMessage(key, values: values)
        text = Self.fill(english, values.map(\.english))
    }
    /// A sentence with another inside it, in its last place: `english` has one more place than `args`.
    public init(_ key: String, _ english: String, _ args: String..., inner: Said) {
        self.init(key, english, values: args.map(SaidValue.text), inner: inner)
    }
    public init(_ key: String, _ english: String, values: [SaidValue], inner: Said) {
        keyed = KeyedMessage(key, values: values, inner: [inner.keyed])
        text = Self.fill(english, values.map(\.english) + [inner.text])
    }
    /// Several sentences inside, in its last places in order.
    public init(_ key: String, _ english: String, inner: [Said]) {
        keyed = KeyedMessage(key, [], inner: inner.map(\.keyed))
        text = Self.fill(english, inner.map(\.text))
    }
    public var description: String { text }
    /// Whether the English says it (what tests and logs look for).
    public func contains(_ s: String) -> Bool { text.contains(s) }
    /// Another error's words, said by its own key when it has one (else as they are: a system's or a plugin's).
    public static func of(_ error: Error) -> Said {
        if let keyed = (error as? KeyedFailure)?.keyed { return Said(text: error.localizedDescription, keyed: keyed) }
        return Said("error.said", "%@", error.localizedDescription)
    }
    public init(text: String, keyed: KeyedMessage) {
        self.text = text
        self.keyed = keyed
    }
    /// A number as a value, with its decimals: the API writes 0.5, the window 0,5 where the region says so.
    public static func n(_ v: Double, _ decimals: Int) -> SaidValue { .number(v, decimals: decimals) }
    /// A number written with as few decimals as it takes (up to six).
    public static func n(_ v: Double) -> SaidValue { .number(v, decimals: nil) }

    /// The English with its values in their places, in one pass (a value is never read as a place).
    static func fill(_ format: String, _ args: [String]) -> String {
        guard !args.isEmpty else { return format }
        var out = "", i = format.startIndex, next = 0
        while i < format.endIndex {
            if format[i] == "%" {
                let rest = format[format.index(after: i)...]
                if rest.hasPrefix("@"), next < args.count {
                    out += args[next]; next += 1
                    i = format.index(i, offsetBy: 2); continue
                }
                if let dollar = rest.firstIndex(of: "$"), let n = Int(rest[..<dollar]), n >= 1, n <= args.count,
                   format[format.index(after: dollar)...].hasPrefix("@") {
                    out += args[n - 1]
                    i = format.index(dollar, offsetBy: 2); continue
                }
            }
            out.append(format[i]); i = format.index(after: i)
        }
        return out
    }
}

/// A sentence for one or for more ("1 clip has", "2 clips have"): the two keys are the same but for `.one`
/// and `.other`, as the catalogue's plural forms would name them.
public func counted(_ n: Int, _ one: Said, _ other: Said) -> Said { n == 1 ? one : other }
