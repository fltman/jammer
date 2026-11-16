import Foundation

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
    static func text(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
    }
    /// A count, in the plural form the language wants.
    static func count(_ key: String, _ n: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), n)
    }
}
