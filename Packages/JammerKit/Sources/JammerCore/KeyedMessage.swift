import Foundation

/// A message by its key in the app's string catalogue, with its values: what lets the window say an
/// error in the window's language while `errorDescription` (and so the agent API) keeps its English words.
/// The values are already text (a name, a formatted number); the catalogue's entry has `%1$@`, `%2$@`
/// where they go. `scripts/check-strings.py` holds each key's English to the words of `errorDescription`.
public struct KeyedMessage: Sendable, Equatable {
    public var key: String
    public var args: [String]
    /// Sentences that go in this one's last places, after `args`, each said in the window's language too
    /// ("The file can't be read as a timeline: %@" with "it isn't JSON." inside).
    public var inner: [KeyedMessage]
    public init(_ key: String, _ args: [String] = [], inner: [KeyedMessage] = []) {
        self.key = key
        self.args = args
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
    /// A sentence with another inside it, in its last place: `english` has one more place than `args`.
    public init(_ key: String, _ english: String, _ args: String..., inner: Said) {
        keyed = KeyedMessage(key, args, inner: [inner.keyed])
        text = Self.fill(english, args + [inner.text])
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
    /// A number as a value: written the same in both languages' sentences (as the API has always said it).
    public static func n(_ v: Double, _ decimals: Int) -> String { String(format: "%.\(decimals)f", v) }

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
