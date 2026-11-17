import Foundation
import JammerCore

/// The window's texts come from the string catalogue (`Localizable.xcstrings`), by key: no text a user
/// sees is written straight in the code (the-apps/SIBLINGS.md, "Språk"; docs/LANGUAGES.md). The agent
/// API's words and what a model writes are not here and are not translated.
///
/// A text with values in it is one entry with placeholders, numbered (`%1$@`, `%2$@`) when there is more
/// than one, so that another language can put them in another order. A count is an entry with the
/// catalogue's plural forms and exactly one number (`%lld`); a sentence is never made by adding a letter.
/// `scripts/check-strings.py` (in the pre-commit check) holds the catalogue and the code to this.
enum L10n {
    /// The text for a key, in the language the app runs in, with its values filled in.
    /// The values are text (a name, a number already written out): the compiler then refuses a number
    /// handed to a place that is written `%@`, which would otherwise crash when the line is shown.
    static func text(_ key: String, _ args: String...) -> String {
        let format = NSLocalizedString(key, comment: "")
        return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args.map { $0 as CVarArg })
    }
    /// An error's reason by its key (`KeyedMessage`, from the packages), in the window's language, as a
    /// sentence of its own: the packages write it to follow a step's name and a colon, so it may start small.
    static func message(_ m: KeyedMessage) -> String {
        let format = NSLocalizedString(m.key, comment: "")
        let text = m.args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: m.args.map { $0 as CVarArg })
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    /// A count, in the plural form the language wants.
    static func count(_ key: String, _ n: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), n)
    }
}
