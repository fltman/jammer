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
    /// An error in the window's language: by its key when it has one, else in its own words (a system's,
    /// a plugin's, a model service's).
    static func error(_ e: Error) -> String {
        if let m = (e as? KeyedFailure)?.keyed { return message(m) }
        return e.localizedDescription
    }
    /// An error's reason by its key (`KeyedMessage`, from the packages), in the window's language, as a
    /// sentence of its own: the packages write it to follow a step's name and a colon, so it may start small.
    static func message(_ m: KeyedMessage) -> String {
        let text = said(m)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    /// A keyed message as written, its inner sentences in its last places.
    private static func said(_ m: KeyedMessage) -> String {
        let format = NSLocalizedString(m.key, comment: "")
        let values = m.args + m.inner.map(said)
        return values.isEmpty ? format : String(format: format, locale: Locale.current, arguments: values.map { $0 as CVarArg })
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
    /// A keyed message standing in for an error (a finished job keeps only its key and its English).
    struct KeyedOnly: Error, KeyedFailure { var keyed: KeyedMessage? }
    /// An error in the assistant's conversation, in the question's language: by its key when it has one.
    static func replyError(_ e: Error, _ language: NLLanguage?) -> String {
        guard let m = (e as? KeyedFailure)?.keyed else { return e.localizedDescription }
        let text = replySaid(m, language)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    private static func replySaid(_ m: KeyedMessage, _ language: NLLanguage?) -> String {
        let format = replyBundle(language).localizedString(forKey: m.key, value: nil, table: nil)
        let values = m.args + m.inner.map { replySaid($0, language) }
        return values.isEmpty ? format : String(format: format, locale: Locale.current, arguments: values.map { $0 as CVarArg })
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
    /// A number written out for a text, with the decimal separator of the Mac's region (as macOS does:
    /// a Swedish region gives "0,3" in either language). No grouping; `sign` writes a plus before a positive.
    static func number(_ v: Double, _ decimals: Int, sign: Bool = false) -> String {
        v.formatted(.number.precision(.fractionLength(decimals)).grouping(.never)
            .sign(strategy: sign ? .always(includingZero: true) : .automatic).locale(Locale.current))
    }
    /// A layout's name in the window: Mono, Stereo, 5.1, 7.1, 7.1.4, Ambisonics (1st Order)…
    static func layoutTitle(_ l: ChannelLayout) -> String {
        switch l {
        case .mono: L10n.text("menu.layout.mono")
        case .stereo: L10n.text("menu.layout.stereo")
        case .ambix1: L10n.text("menu.layout.ambix1")
        case .ambix2: L10n.text("menu.layout.ambix2")
        case .ambix3: L10n.text("menu.layout.ambix3")
        default: l.rawValue
        }
    }
    /// A count, in the plural form the language wants.
    static func count(_ key: String, _ n: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), n)
    }
}
