import Foundation

/// A message by its key in the app's string catalogue, with its values: what lets the window say an
/// error in the window's language while `errorDescription` (and so the agent API) keeps its English words.
/// The values are already text (a name, a formatted number); the catalogue's entry has `%1$@`, `%2$@`
/// where they go. `scripts/check-strings.py` holds each key's English to the words of `errorDescription`.
public struct KeyedMessage: Sendable, Equatable {
    public var key: String
    public var args: [String]
    public init(_ key: String, _ args: [String] = []) {
        self.key = key
        self.args = args
    }
}

/// An error that can be said by key. nil for a case whose words are made where it is thrown (those stay
/// as they were written until each has an entry of its own).
public protocol KeyedFailure: Error {
    var keyed: KeyedMessage? { get }
}
