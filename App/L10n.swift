import Foundation
import NaturalLanguage
import JammerAgent
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
    /// An operation's title in the window's language (`op.<name>.title`), for the menus, the palette, the
    /// assistant's plan and the undo names. The schema keeps the English title for the agent API, and is
    /// what is shown if the catalogue has no entry (the catalogue check fails on that).
    static func operation(_ name: String) -> String {
        let english = Operations.named(name)?.title ?? Operations.endpoints.first { $0.name == name }?.title
            ?? name.replacingOccurrences(of: "_", with: " ").capitalized
        return Bundle.main.localizedString(forKey: "op.\(name).title", value: english, table: nil)
    }
    /// A sentence of the assistant's conversation: in the language of the user's question (a Swedish
    /// question gets a Swedish answer in an English window), or the window's when that can't be told.
    static func reply(_ key: String, _ language: NLLanguage?, _ args: String...) -> String {
        let format = replyBundle(language).localizedString(forKey: key, value: nil, table: nil)
        return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args.map { $0 as CVarArg })
    }
    /// A count in the assistant's conversation, in the question's language.
    static func replyCount(_ key: String, _ language: NLLanguage?, _ n: Int) -> String {
        String.localizedStringWithFormat(replyBundle(language).localizedString(forKey: key, value: nil, table: nil), n)
    }
    private static func replyBundle(_ language: NLLanguage?) -> Bundle {
        let code = language == .swedish ? "sv" : language == .english ? "en" : nil
        guard let code, let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) else { return .main }
        return b
    }
    /// A count, in the plural form the language wants.
    static func count(_ key: String, _ n: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), n)
    }
}
